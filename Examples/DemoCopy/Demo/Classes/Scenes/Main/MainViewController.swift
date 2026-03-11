// Copyright @ MyScript. All rights reserved.

import Foundation
import Combine
import UIKit
import WebKit

/// Protocol called by the MainViewModel, in order to communicate with the Coordinator

protocol MainViewControllerDisplayLogic: AnyObject {
    func displayExportOptions()
    func displayOpenDocumentOptions()
    func displayNewDocumentOptions(cancelEnabled: Bool)
    func displayImagePicker()
    func displayNotebookHome()
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
    private let launchChoiceView = ElaraLaunchChoiceView()
    private var didShowLaunchChoice: Bool = false
    private var toolbarInjected: Bool = false

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
        if self.toolbarInjected == false {
            self.coordinator?.displayToolBar(editingEnabled: false)
            self.toolbarInjected = true
        }
        self.presentLaunchChoiceIfNeeded()
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
        self.viewModel?.$elaraAnalyzeInFlight.removeDuplicates().sink { [weak self] isAnalyzing in
            guard let self = self else { return }
            if isAnalyzing {
                self.elaraCoachDrawerView.isHidden = false
                self.setElaraCoachDrawerExpanded(true, animated: true)
            }
            self.elaraCoachDrawerView.setLoading(isAnalyzing)
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

    private func presentLaunchChoiceIfNeeded(force: Bool = false) {
        if force == false {
            guard self.didShowLaunchChoice == false else {
                return
            }
        }
        guard self.launchChoiceView.superview == nil else {
            return
        }
        self.didShowLaunchChoice = true
        self.launchChoiceView.translatesAutoresizingMaskIntoConstraints = false
        self.launchChoiceView.configure(hasRecentNotebook: self.viewModel?.hasSavedNotebook() ?? false)
        self.launchChoiceView.onContinue = { [weak self] in
            guard let self = self else { return }
            self.launchChoiceView.dismissAnimated {
                self.viewModel?.continueWithLastNotebook()
            }
        }
        self.launchChoiceView.onNewBlank = { [weak self] in
            guard let self = self else { return }
            self.launchChoiceView.dismissAnimated {
                self.viewModel?.startNewBlankNotebook()
            }
        }
        self.launchChoiceView.onOpenNotebook = { [weak self] in
            guard let self = self else { return }
            self.launchChoiceView.dismissAnimated {
                self.viewModel?.openNotebookPicker()
            }
        }
        self.view.addSubview(self.launchChoiceView)
        NSLayoutConstraint.activate([
            self.launchChoiceView.topAnchor.constraint(equalTo: self.view.topAnchor),
            self.launchChoiceView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.launchChoiceView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.launchChoiceView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
        self.launchChoiceView.presentAnimated()
    }

    func didDismissModal() {
        // If the modal closes while no part is loaded (e.g. open list canceled from launch),
        // show the notebook launcher again so users are never stuck on a blank disabled canvas.
        if self.viewModel?.editor?.part == nil {
            self.displayNotebookHome()
        }
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

    func displayNotebookHome() {
        self.didShowLaunchChoice = false
        self.presentLaunchChoiceIfNeeded(force: true)
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
    private let messageView = ElaraMathTextView()
    private let introLabel = UILabel()
    private let focusLabel = UILabel()
    private let feedbackView = ElaraMathTextView()
    private let practiceTitleLabel = UILabel()
    private let practiceProblemView = ElaraMathTextView()
    private let practiceMetaLabel = UILabel()
    private let practiceHintsView = ElaraMathTextView()
    private let actionLabel = UILabel()
    private let practiceButton = UIButton(type: .system)
    private let primaryButton = UIButton(type: .system)
    private let loadingRow = UIStackView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = UILabel()
    private let contentStack = UIStackView()
    private let footerStack = UIStackView()
    private var isExpanded: Bool = false
    private var isLoading: Bool = false
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
        self.messageView.setContent(model.message)
        self.introLabel.isHidden = true
        self.focusLabel.text = model.focusLineText
        self.focusLabel.isHidden = (model.focusLineText == nil)
        if model.feedback.isEmpty {
            self.feedbackView.setContent(nil)
            self.feedbackView.isHidden = true
        } else {
            let feedbackPreview = model.feedback.prefix(3).map { "• \($0)" }.joined(separator: "\n")
            self.feedbackView.setContent(feedbackPreview)
            self.feedbackView.isHidden = false
        }
        if let practiceProblem = model.practiceProblem {
            self.practiceTitleLabel.text = "Practice Problem"
            self.practiceProblemView.setContent(practiceProblem.problemText)
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
            self.practiceHintsView.setContent(hintLines.isEmpty ? nil : hintLines)
            self.practiceTitleLabel.isHidden = false
            self.practiceProblemView.isHidden = false
            self.practiceMetaLabel.isHidden = (self.practiceMetaLabel.text == nil)
            self.practiceHintsView.isHidden = hintLines.isEmpty
        } else {
            self.practiceTitleLabel.text = nil
            self.practiceProblemView.setContent(nil)
            self.practiceMetaLabel.text = nil
            self.practiceHintsView.setContent(nil)
            self.practiceTitleLabel.isHidden = true
            self.practiceProblemView.isHidden = true
            self.practiceMetaLabel.isHidden = true
            self.practiceHintsView.isHidden = true
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

    func setLoading(_ isLoading: Bool) {
        self.isLoading = isLoading
        self.loadingRow.isHidden = (isLoading == false)
        if isLoading {
            self.loadingIndicator.startAnimating()
        } else {
            self.loadingIndicator.stopAnimating()
        }
        self.primaryButton.isEnabled = (isLoading == false)
        self.practiceButton.isEnabled = (isLoading == false)
        self.primaryButton.alpha = isLoading ? 0.65 : 1.0
        self.practiceButton.alpha = isLoading ? 0.65 : 1.0
    }

    func showIntroState() {
        self.titleLabel.text = "Elara Coach"
        self.messageView.setContent("Analyze your page to get step-by-step feedback, targeted revisions, and live guidance.")
        self.introLabel.text = "Use this panel as the main place to start a check, review feedback, and continue the next revision."
        self.introLabel.isHidden = false
        self.focusLabel.text = nil
        self.focusLabel.isHidden = true
        self.feedbackView.setContent(nil)
        self.feedbackView.isHidden = true
        self.practiceTitleLabel.text = nil
        self.practiceTitleLabel.isHidden = true
        self.practiceProblemView.setContent(nil)
        self.practiceProblemView.isHidden = true
        self.practiceMetaLabel.text = nil
        self.practiceMetaLabel.isHidden = true
        self.practiceHintsView.setContent(nil)
        self.practiceHintsView.isHidden = true
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

        self.messageView.defaultTextFont = .systemFont(ofSize: 14, weight: .regular)
        self.messageView.defaultTextColor = .label

        self.introLabel.font = .systemFont(ofSize: 13, weight: .regular)
        self.introLabel.textColor = .secondaryLabel
        self.introLabel.numberOfLines = 0
        self.introLabel.textAlignment = .left

        self.focusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        self.focusLabel.textColor = .secondaryLabel
        self.focusLabel.numberOfLines = 0
        self.focusLabel.textAlignment = .left

        self.feedbackView.defaultTextFont = .systemFont(ofSize: 13, weight: .regular)
        self.feedbackView.defaultTextColor = .secondaryLabel

        self.practiceTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        self.practiceTitleLabel.textColor = .label
        self.practiceTitleLabel.numberOfLines = 1
        self.practiceTitleLabel.textAlignment = .left
        self.practiceTitleLabel.isHidden = true

        self.practiceProblemView.defaultTextFont = .systemFont(ofSize: 14, weight: .regular)
        self.practiceProblemView.defaultTextColor = .label
        self.practiceProblemView.isHidden = true

        self.practiceMetaLabel.font = .systemFont(ofSize: 12, weight: .medium)
        self.practiceMetaLabel.textColor = .secondaryLabel
        self.practiceMetaLabel.numberOfLines = 0
        self.practiceMetaLabel.textAlignment = .left
        self.practiceMetaLabel.isHidden = true

        self.practiceHintsView.defaultTextFont = .systemFont(ofSize: 13, weight: .regular)
        self.practiceHintsView.defaultTextColor = .secondaryLabel
        self.practiceHintsView.isHidden = true

        self.actionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        self.actionLabel.textColor = .label
        self.actionLabel.numberOfLines = 0
        self.actionLabel.textAlignment = .left

        self.loadingIndicator.hidesWhenStopped = false

        self.loadingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        self.loadingLabel.textColor = .secondaryLabel
        self.loadingLabel.numberOfLines = 1
        self.loadingLabel.textAlignment = .left
        self.loadingLabel.text = "Analyzing with Elara..."

        self.loadingRow.axis = .horizontal
        self.loadingRow.alignment = .center
        self.loadingRow.spacing = 8
        self.loadingRow.addArrangedSubview(self.loadingIndicator)
        self.loadingRow.addArrangedSubview(self.loadingLabel)
        self.loadingRow.addArrangedSubview(UIView())
        self.loadingRow.isHidden = true

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
        self.contentStack.addArrangedSubview(self.messageView)
        self.contentStack.addArrangedSubview(self.introLabel)
        self.contentStack.addArrangedSubview(self.focusLabel)
        self.contentStack.addArrangedSubview(self.feedbackView)
        self.contentStack.addArrangedSubview(self.practiceTitleLabel)
        self.contentStack.addArrangedSubview(self.practiceProblemView)
        self.contentStack.addArrangedSubview(self.practiceMetaLabel)
        self.contentStack.addArrangedSubview(self.practiceHintsView)
        self.contentStack.setCustomSpacing(14, after: self.messageView)
        self.contentStack.setCustomSpacing(14, after: self.feedbackView)

        self.footerStack.axis = .vertical
        self.footerStack.alignment = .fill
        self.footerStack.spacing = 10
        self.footerStack.translatesAutoresizingMaskIntoConstraints = false
        self.footerStack.addArrangedSubview(self.loadingRow)
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
        guard self.isLoading == false else {
            return
        }
        self.onPrimaryAction?()
    }

    @objc private func didTapPractice() {
        guard self.isLoading == false else {
            return
        }
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

private final class ElaraMathTextView: UIView {

    var defaultTextFont: UIFont = .systemFont(ofSize: 14, weight: .regular) {
        didSet { self.reloadIfNeeded() }
    }
    var defaultTextColor: UIColor = .label {
        didSet { self.reloadIfNeeded() }
    }

    private let webView: WKWebView
    private var contentHeightConstraint: NSLayoutConstraint!
    private var currentText: String?

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        userContentController.add(WeakScriptMessageHandler(delegate: self), name: "elaraContentHeight")
        self.buildUI()
    }

    required init?(coder: NSCoder) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(coder: coder)
        userContentController.add(WeakScriptMessageHandler(delegate: self), name: "elaraContentHeight")
        self.buildUI()
    }

    deinit {
        self.webView.configuration.userContentController.removeScriptMessageHandler(forName: "elaraContentHeight")
    }

    func setContent(_ text: String?) {
        if self.currentText == text {
            return
        }
        self.currentText = text
        guard let text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            self.contentHeightConstraint.constant = 1
            self.webView.loadHTMLString("<html><body style='margin:0;padding:0;background:transparent;'></body></html>", baseURL: nil)
            return
        }

        let normalized = self.normalizeLatexEscapes(in: text)
        let html = self.buildHTML(from: normalized)
        self.webView.loadHTMLString(html, baseURL: nil)
    }

    private func buildUI() {
        self.translatesAutoresizingMaskIntoConstraints = false
        self.webView.translatesAutoresizingMaskIntoConstraints = false
        self.webView.isOpaque = false
        self.webView.backgroundColor = .clear
        self.webView.scrollView.backgroundColor = .clear
        self.webView.scrollView.isScrollEnabled = false
        self.webView.navigationDelegate = self
        self.addSubview(self.webView)

        self.contentHeightConstraint = self.webView.heightAnchor.constraint(equalToConstant: 1)
        self.contentHeightConstraint.priority = .required
        NSLayoutConstraint.activate([
            self.webView.topAnchor.constraint(equalTo: self.topAnchor),
            self.webView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.webView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.webView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            self.contentHeightConstraint
        ])
    }

    private func reloadIfNeeded() {
        if let currentText {
            self.setContent(currentText)
        }
    }

    private func buildHTML(from text: String) -> String {
        let contentHTML = self.formattedContentHTML(from: text)
        let fontSize = max(12, self.defaultTextFont.pointSize)
        let textHex = self.defaultTextColor.hexString
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <style>
            :root {
              --fg: \(textHex);
              --muted: #5f6368;
              --card: rgba(11, 87, 208, 0.06);
              --line: rgba(0, 0, 0, 0.08);
            }
            body {
              margin: 0;
              padding: 0;
              color: var(--fg);
              background: transparent;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
              font-size: \(fontSize)px;
              line-height: 1.45;
            }
            .root {
              display: flex;
              flex-direction: column;
              gap: 10px;
            }
            .section {
              margin: 0;
              padding: 0;
            }
            .lead {
              background: var(--card);
              border: 1px solid var(--line);
              border-radius: 12px;
              padding: 10px 12px;
            }
            p {
              margin: 0;
              white-space: pre-wrap;
            }
            p + p {
              margin-top: 6px;
            }
            ul {
              margin: 0;
              padding-left: 18px;
            }
            li + li {
              margin-top: 4px;
            }
            .label {
              font-weight: 600;
            }
          </style>
          <script>
            window.MathJax = {
              tex: {
                inlineMath: [['$', '$'], ['\\\\(', '\\\\)']],
                displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']],
                processEscapes: true
              },
              options: {
                skipHtmlTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
              },
              startup: {
                ready: () => {
                  MathJax.startup.defaultReady();
                  reportHeight();
                  setTimeout(reportHeight, 120);
                }
              }
            };
            function reportHeight() {
              const h = Math.max(
                document.documentElement.scrollHeight || 0,
                document.body.scrollHeight || 0
              );
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.elaraContentHeight) {
                window.webkit.messageHandlers.elaraContentHeight.postMessage(Math.ceil(h));
              }
            }
            window.addEventListener('load', () => {
              reportHeight();
              setTimeout(reportHeight, 40);
            });
          </script>
          <script async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"></script>
        </head>
        <body>
          <div class="root">\(contentHTML)</div>
        </body>
        </html>
        """
    }

    private func formattedContentHTML(from text: String) -> String {
        let blocks = self.splitBlocks(from: text)
        var sections: [String] = []
        for (index, block) in blocks.enumerated() {
            let allHints = block.allSatisfy { self.isHintLine($0) }
            if allHints {
                let hints = block.map { line in
                    "<li>\(self.escapeHTML(self.stripHintPrefix(from: line)))</li>"
                }.joined()
                sections.append("<section class=\"section\"><ul>\(hints)</ul></section>")
                continue
            }

            let linesHTML = block.map { line in
                self.formattedLineHTML(from: line)
            }.joined()
            let sectionClass = index == 0 ? "section lead" : "section"
            sections.append("<section class=\"\(sectionClass)\">\(linesHTML)</section>")
        }
        return sections.joined()
    }

    private func splitBlocks(from text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        let lines = text.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if current.isEmpty == false {
                    result.append(current)
                    current = []
                }
                continue
            }
            current.append(line)
        }
        if current.isEmpty == false {
            result.append(current)
        }
        if result.isEmpty {
            return [[text.trimmingCharacters(in: .whitespacesAndNewlines)]]
        }
        return result
    }

    private func formattedLineHTML(from line: String) -> String {
        if line.hasPrefix("• ") || line.hasPrefix("- ") {
            let body = String(line.dropFirst(2))
            return "<ul><li>\(self.escapeHTML(body))</li></ul>"
        }
        if let colonIndex = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colonIndex) <= 24 {
            let prefix = String(line[..<line.index(after: colonIndex)])
            let suffix = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if suffix.isEmpty == false {
                return "<p><span class=\"label\">\(self.escapeHTML(prefix))</span> \(self.escapeHTML(suffix))</p>"
            }
        }
        return "<p>\(self.escapeHTML(line))</p>"
    }

    private func isHintLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.hasPrefix("hint ")
    }

    private func stripHintPrefix(from line: String) -> String {
        if let colonIndex = line.firstIndex(of: ":") {
            return String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line
    }

    private func normalizeLatexEscapes(in text: String) -> String {
        return text.replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func escapeHTML(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&#39;")
        return escaped
    }

    private func updateContentHeight(_ rawValue: Any?) {
        let height: CGFloat
        if let value = rawValue as? CGFloat {
            height = value
        } else if let value = rawValue as? Double {
            height = CGFloat(value)
        } else if let value = rawValue as? NSNumber {
            height = CGFloat(value.doubleValue)
        } else {
            return
        }
        let clamped = max(1, min(height, 2000))
        if abs(self.contentHeightConstraint.constant - clamped) < 0.5 {
            return
        }
        self.contentHeightConstraint.constant = clamped
        self.invalidateIntrinsicContentSize()
        self.superview?.setNeedsLayout()
    }
}

extension ElaraMathTextView: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("Math.max(document.documentElement.scrollHeight || 0, document.body.scrollHeight || 0);") { [weak self] value, _ in
            self?.updateContentHeight(value)
        }
    }
}

extension ElaraMathTextView: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "elaraContentHeight" else {
            return
        }
        self.updateContentHeight(message.body)
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        self.delegate?.userContentController(userContentController, didReceive: message)
    }
}

private extension UIColor {
    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard self.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#111111"
        }
        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

private final class ElaraLaunchChoiceView: UIView {

    var onContinue: (() -> Void)?
    var onNewBlank: (() -> Void)?
    var onOpenNotebook: (() -> Void)?

    private let backgroundGradient = CAGradientLayer()
    private let dimmerView = UIView()
    private let cardView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let buttonStack = UIStackView()
    private let continueButton = UIButton(type: .system)
    private let newButton = UIButton(type: .system)
    private let openButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.buildUI()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.backgroundGradient.frame = self.bounds
    }

    func configure(hasRecentNotebook: Bool) {
        self.continueButton.isEnabled = hasRecentNotebook
        self.continueButton.alpha = hasRecentNotebook ? 1.0 : 0.45
    }

    func presentAnimated() {
        self.alpha = 0
        self.cardView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96).translatedBy(x: 0, y: 10)
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut], animations: {
            self.alpha = 1
            self.cardView.transform = .identity
        }, completion: nil)
    }

    func dismissAnimated(completion: @escaping () -> Void) {
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn], animations: {
            self.alpha = 0
            self.cardView.transform = CGAffineTransform(scaleX: 0.98, y: 0.98).translatedBy(x: 0, y: 6)
        }, completion: { _ in
            self.removeFromSuperview()
            completion()
        })
    }

    private func buildUI() {
        self.translatesAutoresizingMaskIntoConstraints = false
        self.backgroundColor = .clear
        self.backgroundGradient.colors = [
            UIColor(red: 0.93, green: 0.96, blue: 1.00, alpha: 1.0).cgColor,
            UIColor(red: 0.97, green: 0.94, blue: 1.00, alpha: 1.0).cgColor
        ]
        self.backgroundGradient.startPoint = CGPoint(x: 0, y: 0)
        self.backgroundGradient.endPoint = CGPoint(x: 1, y: 1)
        self.layer.addSublayer(self.backgroundGradient)

        self.dimmerView.translatesAutoresizingMaskIntoConstraints = false
        self.dimmerView.backgroundColor = UIColor.black.withAlphaComponent(0.08)
        self.addSubview(self.dimmerView)

        self.cardView.translatesAutoresizingMaskIntoConstraints = false
        self.cardView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        self.cardView.layer.cornerRadius = 20
        self.cardView.layer.cornerCurve = .continuous
        self.cardView.layer.borderWidth = 1
        self.cardView.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        self.cardView.layer.shadowColor = UIColor.black.cgColor
        self.cardView.layer.shadowOpacity = 0.08
        self.cardView.layer.shadowRadius = 14
        self.cardView.layer.shadowOffset = CGSize(width: 0, height: 8)
        self.addSubview(self.cardView)

        self.titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        self.titleLabel.textColor = .label
        self.titleLabel.text = "Welcome to Elara"
        self.titleLabel.numberOfLines = 2

        self.subtitleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        self.subtitleLabel.textColor = .secondaryLabel
        self.subtitleLabel.text = "Pick how you want to start this session."
        self.subtitleLabel.numberOfLines = 0

        self.buttonStack.axis = .vertical
        self.buttonStack.spacing = 12
        self.buttonStack.alignment = .fill
        self.buttonStack.distribution = .fill

        self.continueButton.setTitle("Continue Last Notebook", for: .normal)
        self.newButton.setTitle("New Blank Notebook", for: .normal)
        self.openButton.setTitle("Open Notebook", for: .normal)

        self.styleActionButton(self.continueButton, tint: UIColor.systemTeal)
        self.styleActionButton(self.newButton, tint: UIColor.systemBlue)
        self.styleActionButton(self.openButton, tint: UIColor.systemIndigo)

        self.continueButton.addTarget(self, action: #selector(didTapContinue), for: .touchUpInside)
        self.newButton.addTarget(self, action: #selector(didTapNew), for: .touchUpInside)
        self.openButton.addTarget(self, action: #selector(didTapOpen), for: .touchUpInside)

        self.buttonStack.addArrangedSubview(self.continueButton)
        self.buttonStack.addArrangedSubview(self.newButton)
        self.buttonStack.addArrangedSubview(self.openButton)

        let contentStack = UIStackView(arrangedSubviews: [self.titleLabel, self.subtitleLabel, self.buttonStack])
        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        self.cardView.addSubview(contentStack)

        let preferredWidth = self.cardView.widthAnchor.constraint(equalToConstant: 420)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            self.dimmerView.topAnchor.constraint(equalTo: self.topAnchor),
            self.dimmerView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.dimmerView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.dimmerView.bottomAnchor.constraint(equalTo: self.bottomAnchor),

            self.cardView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            self.cardView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.cardView.leadingAnchor.constraint(greaterThanOrEqualTo: self.leadingAnchor, constant: 24),
            self.cardView.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor, constant: -24),
            preferredWidth,

            contentStack.topAnchor.constraint(equalTo: self.cardView.topAnchor, constant: 22),
            contentStack.leadingAnchor.constraint(equalTo: self.cardView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: self.cardView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: self.cardView.bottomAnchor, constant: -20),

            self.continueButton.heightAnchor.constraint(equalToConstant: 46),
            self.newButton.heightAnchor.constraint(equalToConstant: 46),
            self.openButton.heightAnchor.constraint(equalToConstant: 46)
        ])
    }

    private func styleActionButton(_ button: UIButton, tint: UIColor) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = tint.withAlphaComponent(0.14)
        button.setTitleColor(tint, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.layer.cornerRadius = 12
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = 1
        button.layer.borderColor = tint.withAlphaComponent(0.35).cgColor
    }

    @objc private func didTapContinue() {
        self.onContinue?()
    }

    @objc private func didTapNew() {
        self.onNewBlank?()
    }

    @objc private func didTapOpen() {
        self.onOpenNotebook?()
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
