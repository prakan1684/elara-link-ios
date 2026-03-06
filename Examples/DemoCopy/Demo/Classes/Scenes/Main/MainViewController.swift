// Copyright @ MyScript. All rights reserved.

import Foundation
import Combine
import UIKit

/// Protocol called by the MainViewModel, in order to communicate with the Coordinator

protocol MainViewControllerDisplayLogic: AnyObject {
    func displayExportOptions()
    func displayOpenDocumentOptions()
    func displayNewDocumentOptions(cancelEnabled: Bool)
    func displayImagePicker()
}

/// This is the Main ViewController of the project.
/// It Encapsulates the EditorViewController, permits editing actions (such as undo/redo), and handles pages management.

class MainViewController: UIViewController, Storyboarded {

    // MARK: Outlets

    @IBOutlet weak var containerView: UIView!
    @IBOutlet weak var moreBarButtonItem: UIBarButtonItem!
    @IBOutlet private weak var addPartBarButtonItem: UIBarButtonItem!
    @IBOutlet private weak var previousPartBarButtonItem: UIBarButtonItem!
    @IBOutlet private weak var nextPartBarButtonItem: UIBarButtonItem!
    @IBOutlet private weak var convertBarButtonItem: UIBarButtonItem!
    @IBOutlet private weak var zoomOutBarButtonItem: UIBarButtonItem!
    @IBOutlet private weak var zoomInBarButtonItem: UIBarButtonItem!
    @IBOutlet private weak var navToolbarContainer: UIView!

    // MARK: Properties

    weak var coordinator: MainCoordinator?
    var partTypeToCreate: PartTypeCreationModel? {
        didSet {
            if let partTypeToCreate = self.partTypeToCreate {
                self.viewModel?.createNewPart(partTypeCreationModel: partTypeToCreate, engineProvider: EngineProvider.sharedInstance)
            }
        }
    }
    var fileToOpen: File? {
        didSet {
            if let file = self.fileToOpen {
                self.viewModel?.openFile(file: file, engineProvider: EngineProvider.sharedInstance)
            }
        }
    }
    private(set) var viewModel: MainViewModel?
    private var longPressgestureRecognizer: UILongPressGestureRecognizer?
    private var cancellables: Set<AnyCancellable> = []
    private let elaraCoachDrawerView = ElaraCoachDrawerView()
    private let elaraHighlightsOverlayView = ElaraHighlightsOverlayView()
    private var elaraCoachDrawerTrailingConstraint: NSLayoutConstraint?
    private var elaraCoachDrawerWidthConstraint: NSLayoutConstraint?
    private var elaraCoachDrawerHeightConstraint: NSLayoutConstraint?
    private var isElaraCoachDrawerExpanded: Bool = false
    private var elaraViewportDisplayLink: CADisplayLink?

    // MARK: Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        self.viewModel = MainViewModel(delegate: self,
                                       engineProvider: EngineProvider.sharedInstance,
                                       toolingWorker: ToolingWorker(),
                                       editorWorker: EditorWorker())
        self.bindViewModel()
        self.configureElaraCoachDrawer()
        self.viewModel?.checkEngineProviderValidity()
        self.viewModel?.configureEditor()
        self.viewModel?.enableCaptureStrokePrediction()
        self.coordinator?.displayEditor(editorDelegate: self.viewModel, smartGuideDelegate: self.viewModel)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let fileFound = self.viewModel?.openLastModifiedFileIfAny() ?? false
        self.coordinator?.displayToolBar(editingEnabled: fileFound)
        self.startElaraViewportTrackingIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.elaraViewportDisplayLink?.invalidate()
        self.elaraViewportDisplayLink = nil
    }

    // MARK: Data Binding

    private func bindViewModel() {
        // Enable/Disable buttons and gestures
        self.viewModel?.$addPartItemEnabled.assign(to: \.isEnabled, on: self.addPartBarButtonItem).store(in: &cancellables)
        self.viewModel?.$editingEnabled.assign(to: \.isEnabled, on: self.convertBarButtonItem).store(in: &cancellables)
        self.viewModel?.$editingEnabled.assign(to: \.isEnabled, on: self.zoomInBarButtonItem).store(in: &cancellables)
        self.viewModel?.$editingEnabled.assign(to: \.isEnabled, on: self.zoomOutBarButtonItem).store(in: &cancellables)
        self.viewModel?.$editingEnabled.assign(to: \.isEnabled, on: self.moreBarButtonItem).store(in: &cancellables)
        self.viewModel?.$editingEnabled.sink { [weak self] enabled in
            self?.coordinator?.enableEditing(enable: enabled)
        }.store(in: &cancellables)
        self.viewModel?.$previousButtonEnabled.assign(to: \.isEnabled, on: self.previousPartBarButtonItem).store(in: &cancellables)
        self.viewModel?.$nextButtonEnabled.assign(to: \.isEnabled, on: self.nextPartBarButtonItem).store(in: &cancellables)
        self.viewModel?.$longPressGestureEnabled.removeDuplicates().sink { [weak self] enabled in
            self?.longPressgestureRecognizer?.isEnabled = enabled
        }.store(in: &cancellables)

        // View Model Title
        self.viewModel?.$title.sink { [weak self] title in
            self?.title = title
        }.store(in: &cancellables)

        // AlertViewControllers
        self.viewModel?.$errorAlertModel.sink { [weak coordinator] errorAlertModel in
            guard let alertModel = errorAlertModel else {
                return
            }
            coordinator?.presentAlert(with: alertModel)
        }.store(in: &cancellables)
        self.viewModel?.$menuAlertModel.sink { [weak coordinator] menuAlertModel in
            guard let model = menuAlertModel else {
                return
            }
            coordinator?.presentAlertPopover(with: model)
        }.store(in: &cancellables)
        self.viewModel?.$inputAlertModel.sink { [weak self] inputAlertModel in
            guard let self = self,
                  let model = inputAlertModel else {
                return
            }
            self.coordinator?.presentInputAlert(with: model, delegate: self)
        }.store(in: &cancellables)
        self.viewModel?.$moreActionsAlertModel.sink { [weak coordinator] moreActionsAlertModel in
            guard let model = moreActionsAlertModel else {
                return
            }
            coordinator?.presentAlertPopover(with: model)
        }.store(in: &cancellables)
        self.viewModel?.$elaraCoachCardModel.sink { [weak self] model in
            self?.updateElaraCoachDrawer(with: model)
        }.store(in: &cancellables)
        self.viewModel?.$elaraAnchoredHighlights.sink { [weak self] highlights in
            self?.elaraHighlightsOverlayView.anchoredHighlights = highlights
        }.store(in: &cancellables)
    }

    // MARK: - UI config

    func injectToolbar(toolBar:ToolbarViewController) {
        self.injectViewController(viewController: toolBar, in: self.navToolbarContainer)
    }

    func injectEditor(editor:EditorViewController) {
        self.injectViewController(viewController: editor, in: self.containerView)
        self.configureElaraHighlightsOverlay()
        // Long Press Gesture
        self.longPressgestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(longPressGestureRecognizerAction))
        self.longPressgestureRecognizer?.isEnabled = true
        self.longPressgestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        if let longPressGesture = self.longPressgestureRecognizer {
            editor.view.addGestureRecognizer(longPressGesture)
        }
    }

    private func injectViewController(viewController:UIViewController, in container:UIView) {
        self.addChild(viewController)
        container.addSubview(viewController.view)
        viewController.view.frame = container.bounds
        viewController.didMove(toParent: self)
    }

    private func configureElaraHighlightsOverlay() {
        guard self.elaraHighlightsOverlayView.superview == nil else {
            return
        }
        self.elaraHighlightsOverlayView.translatesAutoresizingMaskIntoConstraints = false
        self.elaraHighlightsOverlayView.isUserInteractionEnabled = false
        self.elaraHighlightsOverlayView.backgroundColor = .clear
        self.containerView.addSubview(self.elaraHighlightsOverlayView)
        NSLayoutConstraint.activate([
            self.elaraHighlightsOverlayView.topAnchor.constraint(equalTo: self.containerView.topAnchor),
            self.elaraHighlightsOverlayView.leadingAnchor.constraint(equalTo: self.containerView.leadingAnchor),
            self.elaraHighlightsOverlayView.trailingAnchor.constraint(equalTo: self.containerView.trailingAnchor),
            self.elaraHighlightsOverlayView.bottomAnchor.constraint(equalTo: self.containerView.bottomAnchor)
        ])
        self.updateElaraHighlightViewport()
    }

    private func startElaraViewportTrackingIfNeeded() {
        guard self.elaraViewportDisplayLink == nil else {
            return
        }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleElaraViewportTick))
        displayLink.add(to: .main, forMode: .common)
        self.elaraViewportDisplayLink = displayLink
    }

    @objc private func handleElaraViewportTick() {
        self.updateElaraHighlightViewport()
    }

    private func updateElaraHighlightViewport() {
        guard let renderer = self.viewModel?.editor?.renderer else {
            return
        }
        self.elaraHighlightsOverlayView.viewport = ElaraViewportTransform(viewTransform: renderer.viewTransform)
    }

    private func configureElaraCoachDrawer() {
        self.elaraCoachDrawerView.translatesAutoresizingMaskIntoConstraints = false
        self.elaraCoachDrawerView.isHidden = false
        self.elaraCoachDrawerView.showIntroState()
        self.elaraCoachDrawerView.onPrimaryAction = { [weak self] in
            self?.viewModel?.performElaraPrimaryAction()
        }
        self.elaraCoachDrawerView.onPracticeAction = { [weak self] in
            self?.viewModel?.insertPendingPracticeProblemFromDrawer()
        }
        self.elaraCoachDrawerView.onToggleExpanded = { [weak self] in
            guard let self = self else { return }
            self.setElaraCoachDrawerExpanded(self.isElaraCoachDrawerExpanded == false, animated: true)
        }

        self.view.addSubview(self.elaraCoachDrawerView)
        self.elaraCoachDrawerTrailingConstraint = self.elaraCoachDrawerView.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: 0)
        self.elaraCoachDrawerWidthConstraint = self.elaraCoachDrawerView.widthAnchor.constraint(equalToConstant: 320)
        self.elaraCoachDrawerHeightConstraint = self.elaraCoachDrawerView.heightAnchor.constraint(equalToConstant: 360)
        let topBound = self.elaraCoachDrawerView.topAnchor.constraint(greaterThanOrEqualTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 8)
        let bottomBound = self.elaraCoachDrawerView.bottomAnchor.constraint(lessThanOrEqualTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        topBound.priority = .required
        bottomBound.priority = .required
        NSLayoutConstraint.activate([
            self.elaraCoachDrawerView.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerYAnchor),
            self.elaraCoachDrawerHeightConstraint!,
            topBound,
            bottomBound,
            self.elaraCoachDrawerTrailingConstraint!,
            self.elaraCoachDrawerWidthConstraint!
        ])
        self.setElaraCoachDrawerExpanded(false, animated: false)
    }

    private func updateElaraCoachDrawer(with model: ElaraCoachCardModel?) {
        guard let model = model else {
            self.elaraCoachDrawerView.showIntroState()
            self.elaraCoachDrawerView.isHidden = false
            self.setElaraCoachDrawerExpanded(false, animated: true)
            return
        }

        self.elaraCoachDrawerView.configure(with: model)
        self.elaraCoachDrawerView.isHidden = false
        self.setElaraCoachDrawerExpanded(true, animated: true)
    }

    private func setElaraCoachDrawerExpanded(_ expanded: Bool, animated: Bool) {
        guard let trailingConstraint = self.elaraCoachDrawerTrailingConstraint,
              let widthConstraint = self.elaraCoachDrawerWidthConstraint,
              let heightConstraint = self.elaraCoachDrawerHeightConstraint else {
            return
        }

        self.isElaraCoachDrawerExpanded = expanded
        let width = min(max(self.view.bounds.width * 0.64, 300), 380)
        let safeAreaHeight = max(self.view.safeAreaLayoutGuide.layoutFrame.height, self.view.bounds.height - self.view.safeAreaInsets.top - self.view.safeAreaInsets.bottom)
        let maxHeight = max(120, safeAreaHeight - 16)
        let preferredHeight = expanded
            ? self.elaraCoachDrawerView.preferredExpandedHeight(for: width)
            : self.elaraCoachDrawerView.preferredCollapsedHeight
        widthConstraint.constant = width
        heightConstraint.constant = min(preferredHeight, maxHeight)
        let visibleTabWidth: CGFloat = 28
        trailingConstraint.constant = expanded ? -8 : (width - visibleTabWidth)
        self.elaraCoachDrawerView.setExpanded(expanded)

        let updates = {
            self.view.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseInOut], animations: updates, completion: nil)
        } else {
            updates()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // resize editor view (after rotation for example)
        for view in self.containerView.subviews {
            view.frame = self.containerView.bounds
        }
        self.elaraHighlightsOverlayView.frame = self.containerView.bounds
        self.updateElaraHighlightViewport()
        self.elaraHighlightsOverlayView.setNeedsDisplay()
        self.setElaraCoachDrawerExpanded(self.isElaraCoachDrawerExpanded, animated: false)
    }

    // MARK: Actions

    @IBAction private func convert(_ sender: Any) {
        self.viewModel?.convert()
    }

    @IBAction private func zoomIn(_ sender: Any) {
        self.viewModel?.zoomIn()
    }

    @IBAction private func zoomOut(_ sender: Any) {
        self.viewModel?.zoomOut()
    }

    @IBAction private func moreButtonTapped(_ sender: Any) {
        self.viewModel?.moreActions(barButtonIdem: self.moreBarButtonItem)
    }

    @IBAction private func nextPart(_ sender: Any) {
        self.viewModel?.loadNextPart()
    }

    @IBAction private func previousPart(_ sender: Any) {
        self.viewModel?.loadPreviousPart()
    }

    @IBAction private func addPart(_ sender: Any) {
        if self.viewModel?.createDefaultElaraPage(onNewPackage: false) == false {
            self.coordinator?.createNewPart(cancelEnabled: true, onNewPackage: false)
        }
    }

    // MARK: LongPress Gesture

    @objc private func longPressGestureRecognizerAction() {
        guard let longPressgestureRecognizer = self.longPressgestureRecognizer else { return }
        let position:CGPoint = longPressgestureRecognizer.location(in: longPressgestureRecognizer.view)
        if let sourceView = longPressgestureRecognizer.view {
            self.viewModel?.handleLongPressGesture(state: longPressgestureRecognizer.state, position: position, sourceView: sourceView)
        }
    }
}

extension MainViewController: MainViewControllerDisplayLogic {

    func displayOpenDocumentOptions() {
        self.coordinator?.openFilesList()
    }

    func displayNewDocumentOptions(cancelEnabled: Bool) {
        if self.viewModel?.createDefaultElaraPage(onNewPackage: true) == false {
            self.coordinator?.createNewPart(cancelEnabled: cancelEnabled, onNewPackage: true)
        }
    }

    func displayExportOptions() {
        self.coordinator?.displayExportOptions(editor: viewModel?.editor)
    }

    func displayImagePicker() {
        self.coordinator?.presentImagePicker(delegate: self)
    }
}

extension MainViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        self.coordinator?.dissmissModal()
        guard let image = info[.originalImage] as? UIImage else {
            return
        }
        self.viewModel?.addImageBlock(with: image)
    }
}

extension MainViewController: UITextFieldDelegate {

    func textFieldDidChangeSelection(_ textField: UITextField) {
        self.viewModel?.addTextBlockValue = textField.text ?? ""
    }
}

extension MainViewController: ToolbarProtocol {

    func undo() {
        self.viewModel?.undo()
    }

    func redo() {
        self.viewModel?.redo()
    }

    func clear() {
        try? self.viewModel?.clear()
    }

    func didSelectTool(tool: IINKPointerTool) {
        self.viewModel?.selectTool(tool: tool)
    }

    func didChangeActivePenMode(activated: Bool) {
        self.viewModel?.didChangeActivePenMode(activated: activated)
    }

    func didSelectStyle(style:ToolStyleModel) {
        self.viewModel?.didSelectStyle(style: style)
    }

    func scanWithElara() {
        self.viewModel?.performElaraPrimaryAction()
    }
}

private final class ElaraCoachDrawerView: UIView {

    var onPrimaryAction: (() -> Void)?
    var onPracticeAction: (() -> Void)?
    var onToggleExpanded: (() -> Void)?

    private let handleButton = UIButton(type: .system)
    private let cardContainer = UIView()
    private let scrollView = UIScrollView()
    private let footerContainer = UIView()
    private let statusChipLabel = UILabel()
    private let confidenceLabel = UILabel()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let introLabel = UILabel()
    private let focusLabel = UILabel()
    private let feedbackLabel = UILabel()
    private let practiceTitleLabel = UILabel()
    private let practiceProblemLabel = UILabel()
    private let practiceMetaLabel = UILabel()
    private let practiceHintsLabel = UILabel()
    private let actionLabel = UILabel()
    private let practiceButton = UIButton(type: .system)
    private let primaryButton = UIButton(type: .system)
    private let contentStack = UIStackView()
    private let footerStack = UIStackView()
    private var isExpanded: Bool = false
    private(set) var preferredCollapsedHeight: CGFloat = 88
    private var practiceButtonAction: PracticeButtonAction = .none

    private enum PracticeButtonAction {
        case none
        case insert
        case request
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.buildUI()
    }

    func configure(with model: ElaraCoachCardModel) {
        self.titleLabel.text = model.title
        self.messageLabel.text = model.message
        self.introLabel.isHidden = true
        self.focusLabel.text = model.focusLineText
        self.focusLabel.isHidden = (model.focusLineText == nil)
        if model.feedback.isEmpty {
            self.feedbackLabel.text = nil
            self.feedbackLabel.isHidden = true
        } else {
            let feedbackPreview = model.feedback.prefix(3).map { "• \($0)" }.joined(separator: "\n")
            self.feedbackLabel.text = feedbackPreview
            self.feedbackLabel.isHidden = false
        }
        if let practiceProblem = model.practiceProblem {
            self.practiceTitleLabel.text = "Practice Problem"
            self.practiceProblemLabel.text = practiceProblem.problemText
            var metaItems: [String] = []
            if let topic = practiceProblem.topic, topic.isEmpty == false {
                metaItems.append(topic)
            }
            if let difficulty = practiceProblem.difficulty, difficulty.isEmpty == false {
                metaItems.append(difficulty.capitalized)
            }
            self.practiceMetaLabel.text = metaItems.isEmpty ? nil : metaItems.joined(separator: " · ")
            let hintLines = practiceProblem.hints.enumerated().map { index, hint in
                return "Hint \(index + 1): \(hint)"
            }.joined(separator: "\n")
            self.practiceHintsLabel.text = hintLines.isEmpty ? nil : hintLines
            self.practiceTitleLabel.isHidden = false
            self.practiceProblemLabel.isHidden = false
            self.practiceMetaLabel.isHidden = (self.practiceMetaLabel.text == nil)
            self.practiceHintsLabel.isHidden = (self.practiceHintsLabel.text == nil)
        } else {
            self.practiceTitleLabel.text = nil
            self.practiceProblemLabel.text = nil
            self.practiceMetaLabel.text = nil
            self.practiceHintsLabel.text = nil
            self.practiceTitleLabel.isHidden = true
            self.practiceProblemLabel.isHidden = true
            self.practiceMetaLabel.isHidden = true
            self.practiceHintsLabel.isHidden = true
        }
        if model.showRecheckPrompt {
            self.actionLabel.text = "You made changes to your work, want to check again?"
            self.primaryButton.setTitle("Check Again", for: .normal)
        } else {
            self.actionLabel.text = "Run Elara again when you want another pass on this work."
            self.primaryButton.setTitle(model.nextActionText, for: .normal)
        }
        self.actionLabel.isHidden = false
        self.primaryButton.isHidden = false
        if model.showPracticeInsertAction {
            self.practiceButton.setTitle("Add Practice Problem to Canvas", for: .normal)
            self.practiceButton.isHidden = false
            self.practiceButtonAction = .insert
        } else {
            self.practiceButton.setTitle("Try New Practice Problem", for: .normal)
            self.practiceButton.isHidden = false
            self.practiceButtonAction = .request
        }
        let confidenceText = model.confidence.map { String(format: "%.0f%%", $0 * 100) }
        self.confidenceLabel.text = confidenceText.map { "Confidence \($0)" }
        self.confidenceLabel.isHidden = (self.confidenceLabel.text == nil)

        let status = model.status ?? "ANALYSIS"
        self.statusChipLabel.text = " \(status) "
        let style = Self.statusStyle(for: status)
        self.statusChipLabel.backgroundColor = style.background
        self.statusChipLabel.textColor = style.foreground
    }

    func setExpanded(_ expanded: Bool) {
        self.isExpanded = expanded
        self.handleButton.setTitle(expanded ? "‹" : "›", for: .normal)
        self.cardContainer.isHidden = (expanded == false)
    }

    func showIntroState() {
        self.titleLabel.text = "Elara Coach"
        self.messageLabel.text = "Analyze your page to get step-by-step feedback, targeted revisions, and live guidance."
        self.introLabel.text = "Use this panel as the main place to start a check, review feedback, and continue the next revision."
        self.introLabel.isHidden = false
        self.focusLabel.text = nil
        self.focusLabel.isHidden = true
        self.feedbackLabel.text = nil
        self.feedbackLabel.isHidden = true
        self.practiceTitleLabel.text = nil
        self.practiceTitleLabel.isHidden = true
        self.practiceProblemLabel.text = nil
        self.practiceProblemLabel.isHidden = true
        self.practiceMetaLabel.text = nil
        self.practiceMetaLabel.isHidden = true
        self.practiceHintsLabel.text = nil
        self.practiceHintsLabel.isHidden = true
        self.actionLabel.text = "Ready when you are."
        self.actionLabel.isHidden = false
        self.practiceButton.isHidden = true
        self.practiceButtonAction = .none
        self.primaryButton.setTitle("Analyze with Elara", for: .normal)
        self.primaryButton.isHidden = false
        self.statusChipLabel.text = " READY "
        let style = Self.statusStyle(for: "READY")
        self.statusChipLabel.backgroundColor = style.background
        self.statusChipLabel.textColor = style.foreground
        self.confidenceLabel.text = nil
        self.confidenceLabel.isHidden = true
    }

    func preferredExpandedHeight(for width: CGFloat) -> CGFloat {
        self.layoutIfNeeded()
        let cardWidth = max(260, width - 20)
        let contentWidth = max(220, cardWidth - 32)
        let targetSize = CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height)
        let contentHeight = self.contentStack.systemLayoutSizeFitting(targetSize,
                                                                      withHorizontalFittingPriority: .required,
                                                                      verticalFittingPriority: .fittingSizeLevel).height
        let footerHeight = self.footerStack.systemLayoutSizeFitting(targetSize,
                                                                    withHorizontalFittingPriority: .required,
                                                                    verticalFittingPriority: .fittingSizeLevel).height
        return max(440, ceil(contentHeight + footerHeight + 72))
    }

    private func buildUI() {
        self.backgroundColor = .clear
        self.layer.masksToBounds = false

        self.handleButton.translatesAutoresizingMaskIntoConstraints = false
        self.handleButton.setTitle("›", for: .normal)
        self.handleButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
        self.handleButton.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        self.handleButton.setTitleColor(.white, for: .normal)
        self.handleButton.layer.cornerRadius = 12
        self.handleButton.layer.borderWidth = 1
        self.handleButton.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        self.handleButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 7, bottom: 8, right: 7)
        self.handleButton.addTarget(self, action: #selector(didTapHandle), for: .touchUpInside)

        self.cardContainer.translatesAutoresizingMaskIntoConstraints = false
        self.cardContainer.backgroundColor = .secondarySystemBackground
        self.cardContainer.layer.cornerRadius = 18
        self.cardContainer.layer.masksToBounds = true
        self.cardContainer.layer.borderWidth = 1
        self.cardContainer.layer.borderColor = UIColor.separator.cgColor

        self.scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.showsVerticalScrollIndicator = true
        self.scrollView.alwaysBounceVertical = false

        self.footerContainer.translatesAutoresizingMaskIntoConstraints = false
        self.footerContainer.backgroundColor = .tertiarySystemBackground

        self.statusChipLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        self.statusChipLabel.layer.cornerRadius = 10
        self.statusChipLabel.layer.masksToBounds = true
        self.statusChipLabel.textAlignment = .center

        self.confidenceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        self.confidenceLabel.textColor = .secondaryLabel

        self.titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        self.titleLabel.textColor = .label
        self.titleLabel.numberOfLines = 2
        self.titleLabel.textAlignment = .left

        self.messageLabel.font = .systemFont(ofSize: 14, weight: .regular)
        self.messageLabel.textColor = .label
        self.messageLabel.numberOfLines = 0
        self.messageLabel.textAlignment = .left

        self.introLabel.font = .systemFont(ofSize: 13, weight: .regular)
        self.introLabel.textColor = .secondaryLabel
        self.introLabel.numberOfLines = 0
        self.introLabel.textAlignment = .left

        self.focusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        self.focusLabel.textColor = .secondaryLabel
        self.focusLabel.numberOfLines = 0
        self.focusLabel.textAlignment = .left

        self.feedbackLabel.font = .systemFont(ofSize: 13, weight: .regular)
        self.feedbackLabel.textColor = .secondaryLabel
        self.feedbackLabel.numberOfLines = 0
        self.feedbackLabel.textAlignment = .left

        self.practiceTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        self.practiceTitleLabel.textColor = .label
        self.practiceTitleLabel.numberOfLines = 1
        self.practiceTitleLabel.textAlignment = .left
        self.practiceTitleLabel.isHidden = true

        self.practiceProblemLabel.font = .systemFont(ofSize: 14, weight: .regular)
        self.practiceProblemLabel.textColor = .label
        self.practiceProblemLabel.numberOfLines = 0
        self.practiceProblemLabel.textAlignment = .left
        self.practiceProblemLabel.isHidden = true

        self.practiceMetaLabel.font = .systemFont(ofSize: 12, weight: .medium)
        self.practiceMetaLabel.textColor = .secondaryLabel
        self.practiceMetaLabel.numberOfLines = 0
        self.practiceMetaLabel.textAlignment = .left
        self.practiceMetaLabel.isHidden = true

        self.practiceHintsLabel.font = .systemFont(ofSize: 13, weight: .regular)
        self.practiceHintsLabel.textColor = .secondaryLabel
        self.practiceHintsLabel.numberOfLines = 0
        self.practiceHintsLabel.textAlignment = .left
        self.practiceHintsLabel.isHidden = true

        self.actionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        self.actionLabel.textColor = .label
        self.actionLabel.numberOfLines = 0
        self.actionLabel.textAlignment = .left

        self.primaryButton.setTitle("Analyze with Elara", for: .normal)
        self.primaryButton.backgroundColor = .systemBlue
        self.primaryButton.setTitleColor(.white, for: .normal)
        self.primaryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        self.primaryButton.titleLabel?.numberOfLines = 2
        self.primaryButton.titleLabel?.lineBreakMode = .byWordWrapping
        self.primaryButton.titleLabel?.textAlignment = .center
        self.primaryButton.layer.cornerRadius = 12
        self.primaryButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        self.primaryButton.addTarget(self, action: #selector(didTapPrimary), for: .touchUpInside)

        self.practiceButton.setTitle("Add Practice Problem to Canvas", for: .normal)
        self.practiceButton.backgroundColor = .systemIndigo
        self.practiceButton.setTitleColor(.white, for: .normal)
        self.practiceButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        self.practiceButton.titleLabel?.numberOfLines = 2
        self.practiceButton.titleLabel?.lineBreakMode = .byWordWrapping
        self.practiceButton.titleLabel?.textAlignment = .center
        self.practiceButton.layer.cornerRadius = 12
        self.practiceButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        self.practiceButton.isHidden = true
        self.practiceButton.addTarget(self, action: #selector(didTapPractice), for: .touchUpInside)

        let headerStack = UIStackView(arrangedSubviews: [self.statusChipLabel, self.confidenceLabel, UIView()])
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 10

        self.contentStack.axis = .vertical
        self.contentStack.alignment = .fill
        self.contentStack.spacing = 10
        self.contentStack.translatesAutoresizingMaskIntoConstraints = false
        self.contentStack.addArrangedSubview(headerStack)
        self.contentStack.addArrangedSubview(self.titleLabel)
        self.contentStack.addArrangedSubview(self.messageLabel)
        self.contentStack.addArrangedSubview(self.introLabel)
        self.contentStack.addArrangedSubview(self.focusLabel)
        self.contentStack.addArrangedSubview(self.feedbackLabel)
        self.contentStack.addArrangedSubview(self.practiceTitleLabel)
        self.contentStack.addArrangedSubview(self.practiceProblemLabel)
        self.contentStack.addArrangedSubview(self.practiceMetaLabel)
        self.contentStack.addArrangedSubview(self.practiceHintsLabel)
        self.contentStack.setCustomSpacing(14, after: self.messageLabel)
        self.contentStack.setCustomSpacing(14, after: self.feedbackLabel)

        self.footerStack.axis = .vertical
        self.footerStack.alignment = .fill
        self.footerStack.spacing = 10
        self.footerStack.translatesAutoresizingMaskIntoConstraints = false
        self.footerStack.addArrangedSubview(self.actionLabel)
        self.footerStack.addArrangedSubview(self.practiceButton)
        self.footerStack.addArrangedSubview(self.primaryButton)

        self.scrollView.addSubview(self.contentStack)
        self.footerContainer.addSubview(self.footerStack)
        self.cardContainer.addSubview(self.scrollView)
        self.cardContainer.addSubview(self.footerContainer)
        self.addSubview(self.cardContainer)
        self.addSubview(self.handleButton)
        NSLayoutConstraint.activate([
            self.handleButton.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 1),
            self.handleButton.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.handleButton.widthAnchor.constraint(equalToConstant: 26),
            self.handleButton.heightAnchor.constraint(equalToConstant: 72),

            self.cardContainer.topAnchor.constraint(equalTo: self.topAnchor),
            self.cardContainer.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 20),
            self.cardContainer.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.cardContainer.bottomAnchor.constraint(equalTo: self.bottomAnchor),

            self.scrollView.topAnchor.constraint(equalTo: self.cardContainer.topAnchor),
            self.scrollView.leadingAnchor.constraint(equalTo: self.cardContainer.leadingAnchor),
            self.scrollView.trailingAnchor.constraint(equalTo: self.cardContainer.trailingAnchor),
            self.scrollView.bottomAnchor.constraint(equalTo: self.footerContainer.topAnchor),

            self.footerContainer.leadingAnchor.constraint(equalTo: self.cardContainer.leadingAnchor),
            self.footerContainer.trailingAnchor.constraint(equalTo: self.cardContainer.trailingAnchor),
            self.footerContainer.bottomAnchor.constraint(equalTo: self.cardContainer.bottomAnchor),

            self.contentStack.topAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.topAnchor, constant: 18),
            self.contentStack.leadingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            self.contentStack.trailingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            self.contentStack.bottomAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.bottomAnchor, constant: -18),
            self.contentStack.widthAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.widthAnchor, constant: -32),

            self.footerStack.topAnchor.constraint(equalTo: self.footerContainer.topAnchor, constant: 14),
            self.footerStack.leadingAnchor.constraint(equalTo: self.footerContainer.leadingAnchor, constant: 16),
            self.footerStack.trailingAnchor.constraint(equalTo: self.footerContainer.trailingAnchor, constant: -16),
            self.footerStack.bottomAnchor.constraint(equalTo: self.footerContainer.bottomAnchor, constant: -16)
        ])
    }

    @objc private func didTapPrimary() {
        self.onPrimaryAction?()
    }

    @objc private func didTapPractice() {
        switch self.practiceButtonAction {
        case .insert:
            self.onPracticeAction?()
        case .request:
            self.onPrimaryAction?()
        case .none:
            break
        }
    }

    @objc private func didTapHandle() {
        self.onToggleExpanded?()
    }

    private static func statusStyle(for status: String) -> (background: UIColor, foreground: UIColor) {
        switch status.uppercased() {
        case "VALID":
            return (UIColor.systemGreen.withAlphaComponent(0.15), UIColor.systemGreen)
        case "INVALID":
            return (UIColor.systemRed.withAlphaComponent(0.15), UIColor.systemRed)
        case "READY":
            return (UIColor.systemGray5, UIColor.secondaryLabel)
        default:
            return (UIColor.systemGray4, UIColor.label)
        }
    }
}

private struct ElaraViewportTransform: Equatable {
    let viewTransform: CGAffineTransform
}

private final class ElaraHighlightsOverlayView: UIView {

    var anchoredHighlights: [ElaraAnchoredHighlight] = [] {
        didSet {
            self.isHidden = anchoredHighlights.isEmpty
            self.setNeedsDisplay()
            self.logDebugProjectionIfNeeded(force: true)
        }
    }

    var viewport: ElaraViewportTransform = ElaraViewportTransform(viewTransform: .identity) {
        didSet {
            self.setNeedsDisplay()
            self.logDebugProjectionIfNeeded(force: false)
        }
    }

    private var lastDebugSignature: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isOpaque = false
        self.isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.isOpaque = false
        self.isHidden = true
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              self.anchoredHighlights.isEmpty == false else {
            return
        }

        context.setLineCap(.round)
        context.setLineJoin(.round)

        for highlight in self.anchoredHighlights {
            let highlightRect = self.project(bbox: highlight.bbox)
            switch highlight.type.lowercased() {
            case "underline":
                self.drawUnderline(in: context, rect: highlightRect, label: highlight.label)
            default:
                self.drawOutline(in: context, rect: highlightRect, label: highlight.label)
            }
        }
    }

    private func drawUnderline(in context: CGContext, rect: CGRect, label: String?) {
        guard rect.isNull == false, rect.isEmpty == false else {
            return
        }
        let underlineY = rect.maxY + 3
        context.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(max(3, rect.height * 0.18))
        context.move(to: CGPoint(x: rect.minX, y: underlineY))
        context.addLine(to: CGPoint(x: rect.maxX, y: underlineY))
        context.strokePath()
        self.drawLabel(label, at: CGPoint(x: rect.minX, y: max(4, rect.minY - 18)))
    }

    private func drawOutline(in context: CGContext, rect: CGRect, label: String?) {
        guard rect.isNull == false, rect.isEmpty == false else {
            return
        }
        context.setStrokeColor(UIColor.systemOrange.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(2)
        context.stroke(rect.insetBy(dx: -1, dy: -1))
        self.drawLabel(label, at: CGPoint(x: rect.minX, y: max(4, rect.minY - 18)))
    }

    private func project(bbox: ElaraBBox) -> CGRect {
        let transform = self.viewport.viewTransform
        let origin = CGPoint(x: bbox.x, y: bbox.y).applying(transform)
        let maxPoint = CGPoint(x: bbox.x + bbox.width, y: bbox.y + bbox.height).applying(transform)
        return CGRect(x: min(origin.x, maxPoint.x),
                      y: min(origin.y, maxPoint.y),
                      width: abs(maxPoint.x - origin.x),
                      height: abs(maxPoint.y - origin.y))
    }

    private func logDebugProjectionIfNeeded(force: Bool) {
        guard let firstHighlight = self.anchoredHighlights.first else {
            self.lastDebugSignature = nil
            return
        }
        let projected = self.project(bbox: firstHighlight.bbox)
        let transform = self.viewport.viewTransform
        let signature = "bbox=\(firstHighlight.bbox.x),\(firstHighlight.bbox.y),\(firstHighlight.bbox.width),\(firstHighlight.bbox.height)|transform=\(transform.a),\(transform.b),\(transform.c),\(transform.d),\(transform.tx),\(transform.ty)|projected=\(projected.origin.x),\(projected.origin.y),\(projected.size.width),\(projected.size.height)|bounds=\(self.bounds.width),\(self.bounds.height)"
        if force == false, self.lastDebugSignature == signature {
            return
        }
        self.lastDebugSignature = signature
        print("[Elara Highlight Projection] type=\(firstHighlight.type) bbox={x=\(firstHighlight.bbox.x), y=\(firstHighlight.bbox.y), width=\(firstHighlight.bbox.width), height=\(firstHighlight.bbox.height)} viewTransform={a=\(transform.a), b=\(transform.b), c=\(transform.c), d=\(transform.d), tx=\(transform.tx), ty=\(transform.ty)} projected={x=\(projected.origin.x), y=\(projected.origin.y), width=\(projected.size.width), height=\(projected.size.height)} overlayBounds={width=\(self.bounds.width), height=\(self.bounds.height)}")
    }

    private func drawLabel(_ label: String?, at point: CGPoint) {
        guard let label, label.isEmpty == false else {
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.systemRed,
            .paragraphStyle: paragraph
        ]
        let attributedString = NSAttributedString(string: label, attributes: attributes)
        attributedString.draw(at: point)
    }
}
