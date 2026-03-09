// Copyright @ MyScript. All rights reserved.

import Foundation
import Combine

protocol MainViewModelEditorLogic: AnyObject {
    func didCreatePackage(fileName: String)
    func didLoadPart(title: String, index: Int, partCount: Int)
    func didUnloadPart()
    func didOpenFile()
}

/// This class is the ViewModel of the MainViewController. It handles all its business logic.

class MainViewModel: NSObject {

    // MARK: - Published Properties

    @Published var title: String?
    // Alerts
    @Published var errorAlertModel: AlertModel?
    @Published var menuAlertModel: AlertModel?
    @Published var moreActionsAlertModel: AlertModel?
    @Published var inputAlertModel: AlertModel?
    @Published var elaraCoachCardModel: ElaraCoachCardModel?
    @Published var elaraHighlights: [ElaraHighlight] = []
    @Published var elaraAnchoredHighlights: [ElaraAnchoredHighlight] = []
    @Published var elaraAnalyzeInFlight: Bool = false
    // Enable/Disable buttons and gestures
    @Published var addPartItemEnabled: Bool = false
    @Published var editingEnabled: Bool = false
    @Published var previousButtonEnabled: Bool = false
    @Published var nextButtonEnabled: Bool = false
    @Published var longPressGestureEnabled: Bool = true

    // MARK: - Properties

    weak var editor: IINKEditor?
    var addTextBlockValue = ""
    private weak var delegate: MainViewControllerDisplayLogic?
    private var activePenModeEnabled: Bool = true
    private var selectedPosition: CGPoint?
    private let tutorAPIClient: TutorAPIClientLogic
    private var isAnalyzing: Bool = false
    private var hasAnalyzedAtLeastOnce: Bool = false
    private var hasEditedSinceLastAnalyze: Bool = false
    private var suppressPostAnalyzeChangeHandling: Bool = false
    private var insertedPracticeProblemSignatures: Set<String> = []
    private var pendingPracticeProblem: ElaraPracticeProblem?
    private let sessionId = UUID().uuidString
    private var lastElaraSnapshotId: String?
    private var lastAnalyzedProvisionalSteps: [ElaraProvisionalStep] = []
    private var engineProvider: EngineProvider
    private var toolingWorker: ToolingWorkerLogic
    private(set) var editorWorker: EditorWorkerLogic

    init(delegate: MainViewControllerDisplayLogic?,
         engineProvider: EngineProvider,
         toolingWorker: ToolingWorkerLogic,
         editorWorker: EditorWorkerLogic,
         tutorAPIClient: TutorAPIClientLogic = TutorAPIClient()) {
        self.engineProvider = engineProvider
        self.delegate = delegate
        self.toolingWorker = toolingWorker
        self.editorWorker = editorWorker
        self.tutorAPIClient = tutorAPIClient
        super.init()
        self.editorWorker.delegate = self
    }

    func checkEngineProviderValidity() {
        if self.engineProvider.engine == nil {
            self.errorAlertModel = AlertModelHelper.createAlert(title: "Certificate Error",
                                                                message: self.engineProvider.engineErrorMessage,
                                                                exitAppWhenClosed: true)
        }
    }

    func openLastModifiedFileIfAny() -> Bool {
        guard let lastOpenedFile = FilesProvider.retrieveLastModifiedFile() else {
            if self.createDefaultElaraPage(onNewPackage: true) == false {
                self.delegate?.displayNewDocumentOptions(cancelEnabled: false)
            }
            return false
        }
        self.openFile(file: lastOpenedFile, engineProvider: self.engineProvider)
        return true
    }

    @discardableResult
    func createDefaultElaraPage(onNewPackage: Bool) -> Bool {
        guard let supportedPartTypes = self.engineProvider.engine?.supportedPartTypes,
              supportedPartTypes.contains("Raw Content") else {
            return false
        }
        let partType = PartTypeModel(partType: "Raw Content",
                                     configuration: "text_math_shape",
                                     displayName: "Raw Content (text_math_shape)")
        self.createNewPart(partTypeCreationModel: PartTypeCreationModel(partType: partType, onNewPackage: onNewPackage),
                           engineProvider: self.engineProvider)
        return true
    }

    // MARK: - Editor Tooling

    func selectTool(tool: IINKPointerTool) {
        do {
            try self.toolingWorker.selectTool(tool: tool, activePenModeEnabled: self.activePenModeEnabled)
            self.longPressGestureEnabled = self.longPressGestureActivationConditon()
        } catch {
            self.handleToolingError(error: error)
        }
    }

    func didChangeActivePenMode(activated: Bool) {
        self.activePenModeEnabled = activated
        self.longPressGestureEnabled = self.longPressGestureActivationConditon()
        do {
            try self.toolingWorker.didChangeActivePenMode(activated: self.activePenModeEnabled)
        } catch {
            self.handleToolingError(error: error)
        }
    }

    func didSelectStyle(style: ToolStyleModel) {
        do {
            try self.toolingWorker.didSelectStyle(style: style)
        } catch {
            self.handleToolingError(error: error)
        }
    }

    private func handleToolingError(error: Error) {
        guard let toolingError = error as? ToolingWorker.ToolingError else {
            return
        }
        self.errorAlertModel = AlertModelHelper.createAlertModel(with: toolingError)
    }

    private func longPressGestureActivationConditon() -> Bool {
        // Don't activate longpress gesture if ActivePen mode is off and tool is not hand or selector
        if  self.activePenModeEnabled == false,
           let currentTool = try? self.editor?.toolController.tool(forType: .pen),
           currentTool.value != .hand,
           currentTool.value != .toolSelector {
            return false
        }
        return true
    }

    // MARK: - Editor Business Logic

    func createNewPart(partTypeCreationModel: PartTypeCreationModel, engineProvider: EngineProvider) {
        do {
            try self.editorWorker.createNewPart(partTypeCreationModel: partTypeCreationModel, engineProvider: engineProvider)
        } catch {
            self.handleEditorError(error: error)
        }
    }

    func loadNextPart() {
        self.editorWorker.loadNextPart()
    }

    func loadPreviousPart() {
        self.editorWorker.loadPreviousPart()
    }

    func undo() {
        self.editorWorker.undo()
    }

    func redo() {
        self.editorWorker.redo()
    }

    func clear() throws {
        do {
            try self.editorWorker.clear()
        } catch {
            self.handleEditorError(error: error)
        }
    }

    func convert(selection: (NSObjectProtocol & IINKIContentSelection)? = nil) {
        do {
            try self.editorWorker.convert(selection: selection)
        } catch {
            self.handleEditorError(error: error)
        }
    }

    func zoomIn() {
        do {
            try self.editorWorker.zoomIn()
        } catch {
            self.handleDefaultError(errorMessage: error.localizedDescription)
        }
    }

    func zoomOut() {
        do {
            try self.editorWorker.zoomOut()
        } catch {
            self.handleDefaultError(errorMessage: error.localizedDescription)
        }
    }

    func openFile(file: File, engineProvider: EngineProvider) {
        self.editorWorker.openFile(file: file, engineProvider: engineProvider)
    }

    func moreActions(barButtonIdem: UIBarButtonItem) {
        var actions: [ActionModel] = []
        let analyzeAction = ActionModel(actionText: "Analyze with Elara") { [weak self] action in
            self?.analyzeWithElara()
        }
        actions.append(analyzeAction)
        let exportAction = ActionModel(actionText: "Export") { [weak self] action in
            self?.delegate?.displayExportOptions()
        }
        actions.append(exportAction)
        let resetViewAction = ActionModel(actionText: "Reset View") { [weak self] action in
            self?.editorWorker.resetView()
            // Ask DisplayViewController to refresh its view
            NotificationCenter.default.post(name: DisplayViewController.refreshNotification, object: nil)
        }
        actions.append(resetViewAction)
        let newAction = ActionModel(actionText: "New") { [weak self] action in
            try? self?.editorWorker.save()
            self?.delegate?.displayNewDocumentOptions(cancelEnabled: true)
        }
        actions.append(newAction)
        let openAction = ActionModel(actionText: "Open") { [weak self] action in
            try? self?.editorWorker.save()
            self?.delegate?.displayOpenDocumentOptions()
        }
        actions.append(openAction)
        let saveAction = ActionModel(actionText: "Save") { [weak self] action in
            do {
                try self?.editorWorker.save()
            } catch {
                self?.handleDefaultError(errorMessage: error.localizedDescription)
            }
        }
        actions.append(saveAction)
        self.moreActionsAlertModel = AlertModel(title: "More actions", alertStyle: .actionSheet, actionModels: actions)
    }

    private func analyzeWithElara() {
        guard self.isAnalyzing == false else {
            return
        }
        guard let request = self.buildAnalyzeRequest() else {
            self.handleDefaultError(errorMessage: "Elara could not read the current page")
            return
        }
        self.setAnalyzingState(true)
        self.tutorAPIClient.analyze(request: request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                self.setAnalyzingState(false)
                switch result {
                case .success(let response):
                    self.lastElaraSnapshotId = response.snapshotId ?? request.snapshotId
                    self.hasAnalyzedAtLeastOnce = true
                    self.hasEditedSinceLastAnalyze = false
                    self.lastAnalyzedProvisionalSteps = request.recognition.provisionalSteps ?? []
                    self.pendingPracticeProblem = response.practiceProblem
                    self.elaraCoachCardModel = self.makeElaraCoachCardModel(from: response, showRecheckPrompt: false)
                    if Self.shouldShowErrorHighlights(for: response) {
                        self.elaraHighlights = response.highlights ?? []
                        self.elaraAnchoredHighlights = self.resolveAnchoredHighlights(from: response, request: request)
                    } else {
                        self.elaraHighlights = []
                        self.elaraAnchoredHighlights = []
                    }
                case .failure(let error):
                    self.handleDefaultError(errorMessage: "Elara analysis failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func setAnalyzingState(_ isAnalyzing: Bool) {
        self.isAnalyzing = isAnalyzing
        self.elaraAnalyzeInFlight = isAnalyzing
    }

    private func buildAnalyzeRequest() -> ElaraAnalyzeRequest? {
        guard let editor = self.editor,
              let rootBlock = editor.rootBlock else {
            return nil
        }
        let supportedMimeTypes = editor.supportedExportMimeTypes(forSelection: rootBlock)
        guard let selectedMimeType = self.preferredMimeType(from: supportedMimeTypes) else {
            return nil
        }
        let extensionString = IINKMimeTypeValue.iinkMimeTypeGetFileExtensions(selectedMimeType.value)
            .components(separatedBy: ",")
            .first ?? ".txt"
        let fileName = "elara-analyze-\(UUID().uuidString)\(extensionString)"
        let exportPath = FileManager.default.pathForFileInTmpDirectory(fileName: fileName)

        do {
            let imagePainter = ImagePainter(imageLoader: ImageLoader())
            editor.waitForIdle()
            try editor.export(selection: rootBlock,
                              destinationFile: exportPath,
                              mimeType: selectedMimeType.value,
                              imagePainter: imagePainter)
        } catch {
            return nil
        }

        defer {
            try? FileManager.default.removeItem(atPath: exportPath)
        }

        guard let exportedData = try? Data(contentsOf: URL(fileURLWithPath: exportPath)) else {
            return nil
        }
        let exportedText = String(data: exportedData, encoding: .utf8)
        let partIdentifier = editor.part?.identifier ?? ""
        let partType = editor.part?.type ?? ""
        let mimeTypeName = IINKMimeTypeValue.iinkMimeTypeGetName(selectedMimeType.value)
        let extractedContent = self.extractRecognitionData(from: exportedText, mimeTypeName: mimeTypeName)
        let renderer = editor.renderer
        let screenBounds = UIScreen.main.bounds
        let clientMeta = ElaraClientMeta(device: "iPad",
                                         appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                                         canvasWidth: Double(screenBounds.width),
                                         canvasHeight: Double(screenBounds.height),
                                         viewScale: Double(renderer.viewScale),
                                         viewOffsetX: Double(renderer.viewOffset.x),
                                         viewOffsetY: Double(renderer.viewOffset.y),
                                         coordinateSpace: "myscript_editor")
        let document = ElaraDocumentRef(partId: partIdentifier, partType: partType)
        let recognition = ElaraRecognitionPayload(mimeType: mimeTypeName,
                                                  rawJiix: exportedText,
                                                  transcriptionText: extractedContent.transcriptionText,
                                                  wordLocations: extractedContent.wordLocations,
                                                  provisionalSteps: extractedContent.provisionalSteps)
        let canvasImage = self.exportCanvasImagePayload(editor: editor, rootBlock: rootBlock)
        let snapshotId = UUID().uuidString
        return ElaraAnalyzeRequest(requestId: UUID().uuidString,
                                   sessionId: self.sessionId,
                                   snapshotId: snapshotId,
                                   lastSnapshotId: self.lastElaraSnapshotId,
                                   timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                                   document: document,
                                   recognition: recognition,
                                   clientMeta: clientMeta,
                                   canvasImage: canvasImage,
                                   exportedDataBase64: exportedText == nil ? exportedData.base64EncodedString() : nil)
    }

    private func preferredMimeType(from supportedMimeTypes: [IINKMimeTypeValue]) -> IINKMimeTypeValue? {
        let preferredExtensions = [".jiix", ".txt", ".md"]
        for preferredExtension in preferredExtensions {
            if let match = supportedMimeTypes.first(where: { mimeType in
                let extensions = IINKMimeTypeValue.iinkMimeTypeGetFileExtensions(mimeType.value)
                return extensions.contains(preferredExtension)
            }) {
                return match
            }
        }
        return supportedMimeTypes.first
    }

    func performElaraPrimaryAction() {
        self.analyzeWithElara()
    }

    func insertPendingPracticeProblemFromDrawer() {
        guard let practiceProblem = self.pendingPracticeProblem else {
            return
        }
        let signature = self.practiceProblemSignature(for: practiceProblem)
        guard self.insertedPracticeProblemSignatures.contains(signature) == false else {
            return
        }
        if self.insertPracticeProblemBlock(practiceProblem) {
            self.insertedPracticeProblemSignatures.insert(signature)
            if var card = self.elaraCoachCardModel {
                card.showPracticeInsertAction = false
                self.elaraCoachCardModel = card
            }
        }
    }

    func dismissElaraCoachCard() {
        self.elaraCoachCardModel = nil
    }

    private func makeElaraCoachCardModel(from response: ElaraAnalyzeResponse, showRecheckPrompt: Bool) -> ElaraCoachCardModel {
        let fallbackTitle: String
        if let status = response.status?.uppercased() {
            fallbackTitle = status == "VALID" ? "Great progress" : "Revise This Step"
        } else {
            fallbackTitle = "Elara Feedback"
        }
        let cleanedTitle = response.agentGoal?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = (cleanedTitle?.isEmpty == false) ? cleanedTitle ?? fallbackTitle : fallbackTitle

        var bodyParts: [String] = []
        if let goalMessage = response.agentGoal?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           goalMessage.isEmpty == false {
            bodyParts.append(goalMessage)
        }
        if let hint = response.hint?.trimmingCharacters(in: .whitespacesAndNewlines),
           hint.isEmpty == false,
           bodyParts.contains(hint) == false {
            bodyParts.append(hint)
        }
        if bodyParts.isEmpty {
            bodyParts.append(response.summary)
        }

        let feedback = response.feedback ?? []
        let focusLineText = response.agentGoal?.focusLineIndex.map { "Focus step: \($0 + 1)" }

        return ElaraCoachCardModel(status: response.status?.uppercased(),
                                   confidence: response.confidence,
                                   title: displayTitle,
                                   message: bodyParts.joined(separator: "\n\n"),
                                   nextActionText: Self.displayText(forAction: response.agentGoal?.nextAction),
                                   showRecheckPrompt: showRecheckPrompt,
                                   showPracticeInsertAction: self.shouldShowPracticeInsertAction(for: response.practiceProblem),
                                   focusLineText: focusLineText,
                                   feedback: feedback,
                                   traceId: response.traceId,
                                   practiceProblem: response.practiceProblem)
    }

    private func insertPracticeProblemBlock(_ practiceProblem: ElaraPracticeProblem) -> Bool {
        guard practiceProblem.problemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              self.editor != nil else {
            return false
        }
        let insertionPoint = self.nextPracticeProblemInsertionPoint()
        let practiceBlockText = self.practiceProblemBlockText(from: practiceProblem)
        let practiceMathExpression = self.practiceProblemMathExpression(from: practiceBlockText)
        do {
            self.suppressPostAnalyzeChangeHandling = true
            try self.editorWorker.addMathBlock(position: insertionPoint, data: practiceMathExpression)
            print("[Elara Practice] Inserted practice problem block at x=\(insertionPoint.x), y=\(insertionPoint.y)")
            DispatchQueue.main.async { [weak self] in
                self?.suppressPostAnalyzeChangeHandling = false
            }
            return true
        } catch {
            print("[Elara Practice] Failed to insert practice problem block: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.suppressPostAnalyzeChangeHandling = false
            }
            return false
        }
    }

    private func shouldShowPracticeInsertAction(for practiceProblem: ElaraPracticeProblem?) -> Bool {
        guard let practiceProblem else {
            return false
        }
        return self.insertedPracticeProblemSignatures.contains(self.practiceProblemSignature(for: practiceProblem)) == false
    }

    private func practiceProblemSignature(for practiceProblem: ElaraPracticeProblem) -> String {
        return [practiceProblem.problemText,
                practiceProblem.topic ?? "",
                practiceProblem.difficulty ?? "",
                practiceProblem.hints.joined(separator: "|")].joined(separator: "::")
    }

    private func nextPracticeProblemInsertionPoint() -> CGPoint {
        if let bottomStep = self.lastAnalyzedProvisionalSteps.max(by: { lhs, rhs in
            let lhsBottom = (lhs.bbox?.y ?? 0) + (lhs.bbox?.height ?? 0)
            let rhsBottom = (rhs.bbox?.y ?? 0) + (rhs.bbox?.height ?? 0)
            return lhsBottom < rhsBottom
        }), let bbox = bottomStep.bbox {
            return CGPoint(x: max(12, CGFloat(bbox.x)), y: CGFloat(bbox.y + bbox.height + 18))
        }
        guard let editor = self.editor else {
            return CGPoint(x: 24, y: 24)
        }
        let visibleOrigin = editor.renderer.viewOffset
        return CGPoint(x: max(12, visibleOrigin.x + 24), y: max(12, visibleOrigin.y + 24))
    }

    private func practiceProblemBlockText(from practiceProblem: ElaraPracticeProblem) -> String {
        return practiceProblem.problemText
    }

    private func practiceProblemMathExpression(from problemText: String) -> String {
        let trimmed = problemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colonIndex = trimmed.lastIndex(of: ":") else {
            return trimmed
        }
        let candidate = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? trimmed : candidate
    }

    private static func displayText(forAction action: String?) -> String {
        guard let action = action?.trimmingCharacters(in: .whitespacesAndNewlines),
              action.isEmpty == false else {
            return "Check Again"
        }
        switch action.uppercased() {
        case "REVISE_AND_CHECK":
            return "Revise & Check"
        case "CHECK_AGAIN":
            return "Check Again"
        default:
            let normalized = action
                .replacingOccurrences(of: "_", with: " ")
                .lowercased()
            return normalized.capitalized
        }
    }

    private static func shouldShowErrorHighlights(for response: ElaraAnalyzeResponse) -> Bool {
        guard let status = response.status?.uppercased() else {
            return false
        }
        return status == "INVALID"
    }

    private func resolveAnchoredHighlights(from response: ElaraAnalyzeResponse,
                                           request: ElaraAnalyzeRequest) -> [ElaraAnchoredHighlight] {
        guard let steps = request.recognition.provisionalSteps, steps.isEmpty == false else {
            print("[Elara Highlight] No provisional steps available to anchor highlight")
            return []
        }

        let matchedStep = steps.first(where: { step in
            if let focusStepId = response.agentGoal?.focusStepId, step.stepId == focusStepId {
                return true
            }
            if let focusLineIndex = response.agentGoal?.focusLineIndex, step.lineIndex == focusLineIndex {
                return true
            }
            return false
        })

        guard let matchedStep, let bbox = matchedStep.bbox else {
            let focusStepId = response.agentGoal?.focusStepId ?? "<none>"
            let focusLineIndex = response.agentGoal?.focusLineIndex.map(String.init) ?? "<none>"
            let availableSteps = steps.map { "\($0.stepId)@line\($0.lineIndex): \($0.text)" }.joined(separator: " | ")
            print("[Elara Highlight] Failed to match anchor. focusStepId=\(focusStepId) focusLineIndex=\(focusLineIndex) availableSteps=\(availableSteps)")
            return []
        }

        let highlightType = response.highlights?.first?.type ?? "underline"
        let highlightLabel = response.highlights?.first?.label
            ?? response.agentGoal?.title

        let bboxString = "x=\(bbox.x), y=\(bbox.y), width=\(bbox.width), height=\(bbox.height)"
        let focusStepId = response.agentGoal?.focusStepId ?? "<none>"
        let focusLineIndex = response.agentGoal?.focusLineIndex.map(String.init) ?? "<none>"
        print("[Elara Highlight] Matched stepId=\(matchedStep.stepId) lineIndex=\(matchedStep.lineIndex) focusStepId=\(focusStepId) focusLineIndex=\(focusLineIndex) type=\(highlightType) bbox={\(bboxString)} text=\"\(matchedStep.text)\"")

        return [ElaraAnchoredHighlight(bbox: bbox,
                                       type: highlightType,
                                       label: highlightLabel)]
    }

    private func preferredImageMimeType(from supportedMimeTypes: [IINKMimeTypeValue]) -> IINKMimeTypeValue? {
        let preferredExtensions = [".png", ".jpg", ".jpeg"]
        for preferredExtension in preferredExtensions {
            if let match = supportedMimeTypes.first(where: { mimeType in
                let extensions = IINKMimeTypeValue.iinkMimeTypeGetFileExtensions(mimeType.value).lowercased()
                return extensions.contains(preferredExtension)
            }) {
                return match
            }
        }
        return nil
    }

    private func exportCanvasImagePayload(editor: IINKEditor, rootBlock: IINKContentBlock) -> ElaraCanvasImagePayload? {
        let supportedMimeTypes = editor.supportedExportMimeTypes(forSelection: rootBlock)
        guard let imageMimeType = self.preferredImageMimeType(from: supportedMimeTypes) else {
            return nil
        }
        let fileExtension = IINKMimeTypeValue.iinkMimeTypeGetFileExtensions(imageMimeType.value)
            .components(separatedBy: ",")
            .first ?? ".png"
        let fileName = "elara-canvas-\(UUID().uuidString)\(fileExtension)"
        let exportPath = FileManager.default.pathForFileInTmpDirectory(fileName: fileName)
        do {
            let imagePainter = ImagePainter(imageLoader: ImageLoader())
            editor.waitForIdle()
            try editor.export(selection: rootBlock,
                              destinationFile: exportPath,
                              mimeType: imageMimeType.value,
                              imagePainter: imagePainter)
            defer {
                try? FileManager.default.removeItem(atPath: exportPath)
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: exportPath)) else {
                return nil
            }
            let image = UIImage(data: data)
            return ElaraCanvasImagePayload(mimeType: IINKMimeTypeValue.iinkMimeTypeGetName(imageMimeType.value),
                                           fileExtension: fileExtension,
                                           width: image.map { Int($0.size.width * $0.scale) },
                                           height: image.map { Int($0.size.height * $0.scale) },
                                           dataBase64: data.base64EncodedString())
        } catch {
            return nil
        }
    }

    private func extractRecognitionData(from exportedText: String?, mimeTypeName: String) -> (transcriptionText: String?, wordLocations: [ElaraWordLocation]?, provisionalSteps: [ElaraProvisionalStep]?) {
        guard let exportedText = exportedText, exportedText.isEmpty == false else {
            return (nil, nil, nil)
        }

        let looksLikeJiix = exportedText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
            && exportedText.contains("\"elements\"")
        if (mimeTypeName.uppercased().contains("JIIX") || looksLikeJiix),
           let data = exportedText.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let elements = json["elements"] as? [[String: Any]] ?? []
            var allWordLocations: [ElaraWordLocation] = []
            var provisionalSteps: [ElaraProvisionalStep] = []
            var stepIndex = 0

            for element in elements {
                let elementType = (element["type"] as? String) ?? "Unknown"
                let elementLabel = (element["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let elementBBox = self.parseBBox(from: element["bounding-box"] as? [String: Any])
                let words = element["words"] as? [[String: Any]] ?? []

                var stepStrokeIds: [String] = []
                var stepWordLocations: [ElaraWordLocation] = []
                for word in words {
                    guard let label = word["label"] as? String, label.isEmpty == false else {
                        continue
                    }
                    let bbox = self.parseBBox(from: word["bounding-box"] as? [String: Any])
                    let candidates = word["candidates"] as? [String]
                    let strokeIds = ((word["items"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
                    stepStrokeIds.append(contentsOf: strokeIds)
                    if let bbox = bbox {
                        let location = ElaraWordLocation(label: label,
                                                         x: bbox.x,
                                                         y: bbox.y,
                                                         width: bbox.width,
                                                         height: bbox.height,
                                                         candidates: candidates,
                                                         strokeIds: strokeIds)
                        allWordLocations.append(location)
                        stepWordLocations.append(location)
                    } else {
                        let location = ElaraWordLocation(label: label,
                                                         x: nil,
                                                         y: nil,
                                                         width: nil,
                                                         height: nil,
                                                         candidates: candidates,
                                                         strokeIds: strokeIds)
                        allWordLocations.append(location)
                        stepWordLocations.append(location)
                    }
                }

                let stepText = (elementLabel?.isEmpty == false ? elementLabel : nil)
                    ?? (stepWordLocations.isEmpty ? nil : stepWordLocations.map { $0.label }.joined(separator: " "))
                guard let stepText else {
                    continue
                }

                provisionalSteps.append(ElaraProvisionalStep(stepId: "step_\(stepIndex)",
                                                             text: stepText,
                                                             elementType: elementType,
                                                             bbox: elementBBox,
                                                             wordLocations: stepWordLocations.isEmpty ? nil : stepWordLocations,
                                                             strokeIds: Array(Set(stepStrokeIds)).sorted(),
                                                             lineIndex: stepIndex))
                stepIndex += 1
            }

            provisionalSteps.sort { lhs, rhs in
                let ly = lhs.bbox?.y ?? Double.greatestFiniteMagnitude
                let ry = rhs.bbox?.y ?? Double.greatestFiniteMagnitude
                if abs(ly - ry) > 0.0001 { return ly < ry }
                let lx = lhs.bbox?.x ?? Double.greatestFiniteMagnitude
                let rx = rhs.bbox?.x ?? Double.greatestFiniteMagnitude
                return lx < rx
            }
            for (index, step) in provisionalSteps.enumerated() {
                provisionalSteps[index] = ElaraProvisionalStep(stepId: step.stepId,
                                                               text: step.text,
                                                               elementType: step.elementType,
                                                               bbox: step.bbox,
                                                               wordLocations: step.wordLocations,
                                                               strokeIds: step.strokeIds,
                                                               lineIndex: index)
            }

            let transcriptionLabels = provisionalSteps.map { $0.text }.filter { $0.isEmpty == false }
            let transcription = transcriptionLabels.isEmpty ? nil : transcriptionLabels.joined(separator: "\n")
            return (transcription,
                    allWordLocations.isEmpty ? nil : allWordLocations,
                    provisionalSteps.isEmpty ? nil : provisionalSteps)
        }

        let fallbackStep = ElaraProvisionalStep(stepId: "step_0",
                                                text: exportedText,
                                                elementType: "Unknown",
                                                bbox: nil,
                                                wordLocations: nil,
                                                strokeIds: [],
                                                lineIndex: 0)
        return (exportedText, nil, [fallbackStep])
    }

    private func parseBBox(from rawBBox: [String: Any]?) -> ElaraBBox? {
        guard let rawBBox else {
            return nil
        }
        guard let x = self.doubleValue(from: rawBBox["x"]),
              let y = self.doubleValue(from: rawBBox["y"]),
              let width = self.doubleValue(from: rawBBox["width"]),
              let height = self.doubleValue(from: rawBBox["height"]) else {
            return nil
        }
        return ElaraBBox(x: x, y: y, width: width, height: height)
    }

    private func doubleValue(from any: Any?) -> Double? {
        if let number = any as? NSNumber {
            return number.doubleValue
        }
        if let value = any as? Double {
            return value
        }
        if let value = any as? Float {
            return Double(value)
        }
        if let value = any as? Int {
            return Double(value)
        }
        return nil
    }

    func handleLongPressGesture(state: UIGestureRecognizer.State,
                                position: CGPoint,
                                sourceView: UIView) {
        if state == .began, let editor = self.editor {
            var block: (NSObjectProtocol & IINKIContentSelection)? = editor.rootBlock
            if let selectionBlock = editor.hitSelection(position) {
                block = selectionBlock
            } else if let hitBlock = editor.hitBlock(position) {
                block = hitBlock
            }
            if let block = block {
                let sourceRect: CGRect = CGRect(x: position.x, y: position.y, width: 1, height: 1)
                self.createMoreMenu(with: block,
                                    position: position,
                                    sourceView: sourceView,
                                    sourceRect: sourceRect)
            }
        }
    }

    func addImageBlock(with image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 1),
              let position = self.selectedPosition else {
            return
        }
        do {
            try self.editorWorker.addImageBlock(data: data, position: position)
        } catch {
            self.handleEditorError(error: error)
        }
    }

    func configureEditor() {
        self.editorWorker.configureEditor()
    }

    func enableCaptureStrokePrediction() {
        self.editorWorker.enableCaptureStrokePrediction()
    }

    private func handleEditorError(error: Error) {
        guard let editorError = error as? EditorWorker.EditorError else {
            return
        }
        self.errorAlertModel = AlertModelHelper.createAlertModel(with: editorError)
    }

    private func createMoreMenu(with content: NSObjectProtocol & IINKIContentSelection,
                                position: CGPoint,
                                sourceView: UIView?,
                                sourceRect: CGRect) {
        guard let editor = self.editor else {
            return
        }
        self.selectedPosition = position
        var actionModels: [ActionModel] = []
        let analyzeAction = ActionModel(actionText: "Analyze with Elara") { [weak self] action in
            self?.analyzeWithElara()
        }
        actionModels.append(analyzeAction)
        let actions = ContextualActionsHelper.availableActions(forContent: content, editor: editor)
        // Fill actionModels
        if actions.contains(.addBlock) {
            for type in editor.supportedAddBlockTypes {
                if type == "Text" {
                    let actionTitle = "Add Text"
                    let action = ActionModel(actionText: actionTitle) { [weak self] action in
                        let inputAction = ActionModel(actionText: actionTitle) { [weak self] action in
                            do {
                                try self?.editorWorker.addTextBlock(position: position, data: self?.addTextBlockValue ?? "")
                            } catch {
                                self?.handleDefaultError(errorMessage: error.localizedDescription)
                            }
                        }
                        self?.inputAlertModel = AlertModel(title: actionTitle,
                                                           actionModels: [inputAction])
                    }
                    actionModels.append(action)
                } else if type == "Image" {
                    let action = ActionModel(actionText: "Add Image") { [weak self] action in
                        self?.delegate?.displayImagePicker()
                    }
                    actionModels.append(action)
                } else if type == "Placeholder" {
                    // not supported
                } else {
                    let addTitle = String(format: "Add %@", type)
                    let action = ActionModel(actionText: addTitle) { [weak self] action in
                        do {
                            try self?.editorWorker.addBlock(position: position, type: type)
                        } catch {
                            self?.handleDefaultError(errorMessage: error.localizedDescription)
                        }
                    }
                    actionModels.append(action)
                }
            }
        }
        if actions.contains(.remove) {
            let action = ActionModel(actionText: "Remove") { [weak self] action in
                do {
                    try self?.editorWorker.erase(selection: content)
                } catch {
                    self?.handleDefaultError(errorMessage: error.localizedDescription)
                }
            }
            actionModels.append(action)
        }
        if actions.contains(.copy) {
            let action = ActionModel(actionText: "Copy") { [weak self] action in
                do {
                    try self?.editorWorker.copy(selection: content)
                } catch {
                    self?.handleDefaultError(errorMessage: error.localizedDescription)
                }
            }
            actionModels.append(action)
        }
        if actions.contains(.paste) {
            let action = ActionModel(actionText: "Paste") { [weak self] action in
                do {
                    try self?.editorWorker.paste(at: position)
                } catch {
                    self?.handleDefaultError(errorMessage: error.localizedDescription)
                }
            }
            actionModels.append(action)
        }
        if actions.contains(.exportData) {
            let action = ActionModel(actionText: "Export") { [weak self] action in
                self?.delegate?.displayExportOptions()
            }
            actionModels.append(action)
        }
        if actions.contains(.convert) {
            let action = ActionModel(actionText: "Convert") { [weak self] action in
                self?.convert(selection: content)
            }
            actionModels.append(action)
        }
        if actions.contains(.formatText) {
            let action = ActionModel(actionText: "Format Text") { [weak self] action in
                self?.createFormatTextMenu(selection: content,
                                           sourceView: sourceView,
                                           sourceRect: sourceRect)
            }
            actionModels.append(action)
        }

        if actionModels.count > 0 {
            self.menuAlertModel = AlertModel(alertStyle: .actionSheet,
                                             actionModels: actionModels,
                                             sourceView: sourceView,
                                             sourceRect: sourceRect)
        }
    }

    private func createFormatTextMenu(selection: NSObjectProtocol & IINKIContentSelection,
                                      sourceView: UIView?,
                                      sourceRect: CGRect) {
        DispatchQueue.main.async {
            guard let editor = self.editor else {
                return
            }
            let formats = editor.supportedTextFormats(forSelection: selection)
            var actionModels: [ActionModel] = []
            for format in formats {
                let action = ActionModel(actionText: TextFormatHelper.name(for: format.value)) { [weak self] action in
                    do {
                        try self?.editorWorker.set(textFormat: format.value, selection: selection)
                    } catch {
                        self?.handleDefaultError(errorMessage: error.localizedDescription)
                    }
                }
                actionModels.append(action)
            }
            if actionModels.count > 0 {
                self.menuAlertModel = AlertModel(alertStyle: .actionSheet,
                                             actionModels: actionModels,
                                             sourceView: sourceView,
                                             sourceRect: sourceRect)
            }
        }
    }

    private func handleDefaultError(errorMessage: String) {
        self.errorAlertModel = AlertModelHelper.createDefaultErrorAlert(message: errorMessage,
                                                                        exitAppWhenClosed: false)
    }
}

// MARK: - Delegates

extension MainViewModel: EditorDelegate {

    func didCreateEditor(editor: IINKEditor) {
        self.editor = editor
        self.toolingWorker.editor = editor
        self.editorWorker.editor = editor
    }

    func partChanged(editor: IINKEditor) {

    }

    func contentChanged(editor: IINKEditor, blockIds: [String]) {
        self.handlePostAnalyzeContentChange(editor: editor, blockIds: blockIds)

        // Auto-solve isolated Math blocks
        guard let mathSolver = editor.mathSolverController else {
            return
        }
        for blockId in blockIds {
            let block = editor.getBlockById(blockId)
            if block?.type == "Math" && editor.part?.type == "Raw Content" && block?.parent?.type != "Text" {
                do {
                    let configStrokes = editor.engine.createParameterSet()
                    try configStrokes?.set(string: "strokes", forKey: "math.solver.rendered-ink-type")
                    let configGlyphs = editor.engine.createParameterSet()
                    try configGlyphs?.set(string: "glyphs", forKey: "math.solver.rendered-ink-type")

                    let solveAsStrokes = try mathSolver.diagnostic(forBlock: blockId, task: "numerical-computation", overrideConfiguration: configStrokes)
                    let solveAsGlyphs  = try mathSolver.diagnostic(forBlock: blockId, task: "numerical-computation", overrideConfiguration: configGlyphs)

                    if solveAsStrokes.value.rawValue == IINKMathDiagnostic.allowed.rawValue && solveAsGlyphs.value.rawValue == IINKMathDiagnostic.allowed.rawValue { // not already solved as strokes or glyphs
                        let conversionState = try editor.conversionState(forSelection: block)
                        let config = ((conversionState.value.rawValue & IINKConversionState.handwriting.rawValue) != 0) ? configStrokes : configGlyphs

                        try mathSolver.apply(forBlock: blockId, action: "numerical-computation", overrideConfiguration: config)
                    }
                }
                catch {
                    self.handleEditorError(error: error)
                }
            }
        }
    }

    private func handlePostAnalyzeContentChange(editor: IINKEditor, blockIds: [String]) {
        guard self.suppressPostAnalyzeChangeHandling == false else {
            return
        }
        let shouldClearHighlights = self.shouldClearHighlights(editor: editor, blockIds: blockIds)
        let update = { [weak self] in
            guard let self = self else { return }
            if self.hasAnalyzedAtLeastOnce,
               self.isAnalyzing == false,
               self.hasEditedSinceLastAnalyze == false {
                self.hasEditedSinceLastAnalyze = true
                if var card = self.elaraCoachCardModel {
                    card.showRecheckPrompt = true
                    self.elaraCoachCardModel = card
                }
            }
            if shouldClearHighlights {
                self.elaraHighlights = []
                self.elaraAnchoredHighlights = []
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func shouldClearHighlights(editor: IINKEditor, blockIds: [String]) -> Bool {
        guard self.elaraAnchoredHighlights.isEmpty == false else {
            return false
        }
        let highlightedRects = self.elaraAnchoredHighlights.map { highlight in
            CGRect(x: highlight.bbox.x,
                   y: highlight.bbox.y,
                   width: highlight.bbox.width,
                   height: highlight.bbox.height)
        }
        for blockId in blockIds {
            guard let block = editor.getBlockById(blockId) else {
                continue
            }
            let blockRect = block.box
            if highlightedRects.contains(where: { $0.intersects(blockRect) }) {
                print("[Elara Highlight] Clearing stale highlight due to intersecting edit on blockId=\(blockId) blockBox=\(NSCoder.string(for: blockRect))")
                return true
            }
        }
        return false
    }

    func onError(editor: IINKEditor, blockId: String, message: String) {
        self.handleDefaultError(errorMessage: message)
    }
}

extension MainViewModel: SmartGuideViewControllerDelegate {

    func smartGuideViewController(_ smartGuideViewController: SmartGuideViewController!,
                                  didTapOnMoreButton moreButton: UIButton!,
                                  for block: IINKContentBlock!) {
        self.createMoreMenu(with: block,
                            position: CGPoint.zero,
                            sourceView: moreButton,
                            sourceRect: moreButton.bounds)
    }

    func smartGuideViewController(_ smartGuideViewController: SmartGuideViewController!,
                                  didTapOnElaraButton elaraButton: UIButton!,
                                  for block: IINKContentBlock!) {
        self.analyzeWithElara()
    }
}

extension MainViewModel: MainViewModelEditorLogic {

    func didCreatePackage(fileName: String) {
        self.addPartItemEnabled = true
    }

    func didLoadPart(title: String, index: Int, partCount: Int) {
        // Enable buttons
        self.editingEnabled = true
        self.previousButtonEnabled = index > 0
        self.nextButtonEnabled = index < partCount - 1
        self.elaraHighlights = []
        self.elaraAnchoredHighlights = []
        // Set title
        self.title = title
    }

    func didUnloadPart() {
        self.title = ""
        self.editingEnabled = false
        self.elaraHighlights = []
        self.elaraAnchoredHighlights = []
    }

    func didOpenFile() {
        self.addPartItemEnabled = true
        self.previousButtonEnabled = false
    }
}

protocol TutorAPIClientLogic {
    func analyze(request: ElaraAnalyzeRequest, completion: @escaping (Result<ElaraAnalyzeResponse, Error>) -> Void)
}

struct ElaraAnalyzeRequest: Codable {
    let requestId: String
    let sessionId: String
    let snapshotId: String
    let lastSnapshotId: String?
    let timestampMs: Int64
    let document: ElaraDocumentRef
    let recognition: ElaraRecognitionPayload
    let clientMeta: ElaraClientMeta
    let canvasImage: ElaraCanvasImagePayload?
    let exportedDataBase64: String?
}

struct ElaraDocumentRef: Codable {
    let partId: String
    let partType: String
}

struct ElaraClientMeta: Codable {
    let device: String
    let appVersion: String
    let canvasWidth: Double
    let canvasHeight: Double
    let viewScale: Double
    let viewOffsetX: Double
    let viewOffsetY: Double
    let coordinateSpace: String
}

struct ElaraCanvasImagePayload: Codable {
    let mimeType: String
    let fileExtension: String
    let width: Int?
    let height: Int?
    let dataBase64: String
}

struct ElaraRecognitionPayload: Codable {
    let mimeType: String
    let rawJiix: String?
    let transcriptionText: String?
    let wordLocations: [ElaraWordLocation]?
    let provisionalSteps: [ElaraProvisionalStep]?
}

struct ElaraBBox: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ElaraWordLocation: Codable {
    let label: String
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let candidates: [String]?
    let strokeIds: [String]?
}

struct ElaraProvisionalStep: Codable {
    let stepId: String
    let text: String
    let elementType: String
    let bbox: ElaraBBox?
    let wordLocations: [ElaraWordLocation]?
    let strokeIds: [String]
    let lineIndex: Int
}

struct ElaraAnalyzeResponse: Codable {
    let summary: String
    let feedback: [String]?
    let snapshotId: String?
    let status: String?
    let confidence: Double?
    let hint: String?
    let agentGoal: ElaraAgentGoal?
    let highlights: [ElaraHighlight]?
    let traceId: String?
    let practiceProblem: ElaraPracticeProblem?

    enum CodingKeys: String, CodingKey {
        case summary
        case feedback
        case snapshotId
        case status
        case confidence
        case hint
        case agentGoal
        case highlights
        case traceId
        case practiceProblem = "practice_problem"
    }
}

struct ElaraAgentGoal: Codable {
    let intent: String?
    let title: String?
    let message: String?
    let nextAction: String?
    let toolsPlanned: [String]?
    let toolsUsed: [String]?
    let focusStepId: String?
    let focusLineIndex: Int?

    enum CodingKeys: String, CodingKey {
        case intent
        case title
        case message
        case nextAction = "next_action"
        case toolsPlanned = "tools_planned"
        case toolsUsed = "tools_used"
        case focusStepId = "focus_step_id"
        case focusLineIndex = "focus_line_index"
    }
}

struct ElaraHighlight: Codable {
    let bbox: ElaraBBox
    let type: String
    let label: String?
}

struct ElaraAnchoredHighlight {
    let bbox: ElaraBBox
    let type: String
    let label: String?
}

struct ElaraPracticeProblem: Codable {
    let problemText: String
    let topic: String?
    let difficulty: String?
    let hints: [String]
    let sourceSnapshotId: String?

    enum CodingKeys: String, CodingKey {
        case problemText = "problem_text"
        case topic
        case difficulty
        case hints
        case sourceSnapshotId = "source_snapshot_id"
    }
}

struct ElaraCoachCardModel {
    let status: String?
    let confidence: Double?
    let title: String
    let message: String
    let nextActionText: String
    var showRecheckPrompt: Bool
    var showPracticeInsertAction: Bool
    let focusLineText: String?
    let feedback: [String]
    let traceId: String?
    let practiceProblem: ElaraPracticeProblem?
}

class TutorAPIClient: TutorAPIClientLogic {

    private let endpointURL: URL?

    init() {
        if let endpoint = Bundle.main.object(forInfoDictionaryKey: "ELARA_ANALYZE_URL") as? String,
           endpoint.isEmpty == false {
            self.endpointURL = URL(string: endpoint)
        } else {
            self.endpointURL = nil
        }
    }

    func analyze(request: ElaraAnalyzeRequest, completion: @escaping (Result<ElaraAnalyzeResponse, Error>) -> Void) {
        Self.logAnalyzeRequest(request)
        guard let endpointURL = self.endpointURL else {
            // Mock fallback keeps the frontend workflow usable until the backend URL is configured.
            let preview = request.recognition.transcriptionText?.prefix(120)
                ?? request.recognition.rawJiix?.prefix(120)
                ?? "No text preview available."
            let mockResponse = ElaraAnalyzeResponse(summary: "Elara analyzed your page.",
                                                    feedback: ["Preview: \(preview)", "Add ELARA_ANALYZE_URL in Info.plist to call your backend."],
                                                    snapshotId: request.snapshotId,
                                                    status: nil,
                                                    confidence: nil,
                                                    hint: nil,
                                                    agentGoal: nil,
                                                    highlights: nil,
                                                    traceId: nil,
                                                    practiceProblem: nil)
            completion(.success(mockResponse))
            return
        }

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  let data = data else {
                completion(.failure(NSError(domain: "TutorAPIClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response from server"])))
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(NSError(domain: "TutorAPIClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode)"])))
                return
            }
            do {
                let result = try Self.decodeAnalyzeResponse(from: data)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func decodeAnalyzeResponse(from data: Data) throws -> ElaraAnalyzeResponse {
        if let legacy = try? JSONDecoder().decode(ElaraAnalyzeResponse.self, from: data) {
            return legacy
        }
        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "TutorAPIClient",
                          code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported response format"])
        }

        let responseSnapshotId = Self.firstString(in: jsonObject, keys: ["snapshotId", "snapshot_id", "newSnapshotId", "new_snapshot_id"])
            ?? Self.firstString(inNestedDictionariesOf: jsonObject, keys: ["snapshotId", "snapshot_id", "newSnapshotId", "new_snapshot_id"])
        let status = Self.firstString(in: jsonObject, keys: ["status"])
            ?? Self.firstString(inNestedDictionariesOf: jsonObject, keys: ["status"])
        let confidence = Self.firstDouble(in: jsonObject, keys: ["confidence"])
        let hint = Self.firstString(in: jsonObject, keys: ["hint"])
            ?? Self.firstString(inNestedDictionariesOf: jsonObject, keys: ["hint"])
        let agentGoal = Self.extractAgentGoal(from: jsonObject)
        let highlights = Self.extractHighlights(from: jsonObject)
        let practiceProblem = Self.extractPracticeProblem(from: jsonObject)
        let traceId = Self.firstString(in: jsonObject, keys: ["traceId", "trace_id"])
            ?? Self.firstString(inNestedDictionariesOf: jsonObject, keys: ["traceId", "trace_id"])

        let summary = Self.extractSummary(from: jsonObject)
            ?? hint
            ?? agentGoal?.message
            ?? "Elara analysis completed."
        let feedback = Self.extractFeedback(from: jsonObject)

        return ElaraAnalyzeResponse(summary: summary,
                                    feedback: feedback?.isEmpty == true ? nil : feedback,
                                    snapshotId: responseSnapshotId,
                                    status: status,
                                    confidence: confidence,
                                    hint: hint,
                                    agentGoal: agentGoal,
                                    highlights: highlights,
                                    traceId: traceId,
                                    practiceProblem: practiceProblem)
    }

    private static func extractSummary(from json: [String: Any]) -> String? {
        if let summary = Self.firstString(in: json, keys: ["summary", "message", "resultMessage", "analysisSummary"]),
           summary.isEmpty == false {
            return summary
        }
        for key in ["result", "data", "response", "checkResponse"] {
            if let nested = json[key] as? [String: Any],
               let summary = Self.extractSummary(from: nested),
               summary.isEmpty == false {
                return summary
            }
        }
        return nil
    }

    private static func extractFeedback(from json: [String: Any]) -> [String]? {
        if let feedbackStrings = Self.extractStringArray(from: json, keys: ["feedback", "messages", "notes"]),
           feedbackStrings.isEmpty == false {
            return feedbackStrings
        }

        for key in ["checks", "results", "items", "violations"] {
            guard let objects = json[key] as? [[String: Any]], objects.isEmpty == false else {
                continue
            }
            let lines = objects.compactMap(Self.flattenObjectLine(from:))
            if lines.isEmpty == false {
                return lines
            }
        }

        for key in ["result", "data", "response", "checkResponse"] {
            if let nested = json[key] as? [String: Any],
               let nestedFeedback = Self.extractFeedback(from: nested),
               nestedFeedback.isEmpty == false {
                return nestedFeedback
            }
        }
        return nil
    }

    private static func extractStringArray(from json: [String: Any], keys: [String]) -> [String]? {
        for key in keys {
            if let values = json[key] as? [String] {
                return values
            }
            if let values = json[key] as? [Any] {
                let strings = values.compactMap { value -> String? in
                    if let stringValue = value as? String {
                        return stringValue
                    }
                    if let objectValue = value as? [String: Any] {
                        return Self.flattenObjectLine(from: objectValue)
                    }
                    return nil
                }
                if strings.isEmpty == false {
                    return strings
                }
            }
        }
        return nil
    }

    private static func flattenObjectLine(from object: [String: Any]) -> String? {
        let primary = Self.firstString(in: object,
                                       keys: ["message", "text", "feedback", "detail", "description", "reason"])
        let title = Self.firstString(in: object,
                                     keys: ["title", "check", "name", "code", "kind"])
        let status = Self.firstString(in: object,
                                      keys: ["status", "severity", "level", "verdict"])

        if let title, let primary, title != primary {
            return "\(title): \(primary)"
        }
        if let primary {
            return primary
        }
        if let title, let status {
            return "\(title): \(status)"
        }
        return title ?? status
    }

    private static func firstString(in json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func firstString(inNestedDictionariesOf json: [String: Any], keys: [String]) -> String? {
        for value in json.values {
            if let nested = value as? [String: Any],
               let result = Self.firstString(in: nested, keys: keys) {
                return result
            }
        }
        return nil
    }

    private static func firstDouble(in json: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = json[key] as? Double {
                return value
            }
            if let value = json[key] as? NSNumber {
                return value.doubleValue
            }
        }
        return nil
    }

    private static func extractAgentGoal(from json: [String: Any]) -> ElaraAgentGoal? {
        if let goalObject = (json["agent_goal"] as? [String: Any]) ?? (json["agentGoal"] as? [String: Any]) {
            return ElaraAgentGoal(intent: Self.firstString(in: goalObject, keys: ["intent"]),
                                  title: Self.firstString(in: goalObject, keys: ["title"]),
                                  message: Self.firstString(in: goalObject, keys: ["message"]),
                                  nextAction: Self.firstString(in: goalObject, keys: ["next_action", "nextAction"]),
                                  toolsPlanned: Self.stringArray(in: goalObject, keys: ["tools_planned", "toolsPlanned"]),
                                  toolsUsed: Self.stringArray(in: goalObject, keys: ["tools_used", "toolsUsed"]),
                                  focusStepId: Self.firstString(in: goalObject, keys: ["focus_step_id", "focusStepId"]),
                                  focusLineIndex: Self.firstInt(in: goalObject, keys: ["focus_line_index", "focusLineIndex"]))
        }
        for key in ["result", "data", "response", "checkResponse"] {
            if let nested = json[key] as? [String: Any],
               let nestedGoal = Self.extractAgentGoal(from: nested) {
                return nestedGoal
            }
        }
        return nil
    }

    private static func extractHighlights(from json: [String: Any]) -> [ElaraHighlight]? {
        if let highlightObjects = json["highlights"] as? [[String: Any]] {
            let highlights = highlightObjects.compactMap { object -> ElaraHighlight? in
                guard let bboxObject = object["bbox"] as? [String: Any],
                      let bbox = Self.parseBBox(from: bboxObject),
                      let type = Self.firstString(in: object, keys: ["type"]) else {
                    return nil
                }
                return ElaraHighlight(bbox: bbox,
                                      type: type,
                                      label: Self.firstString(in: object, keys: ["label"]))
            }
            return highlights.isEmpty ? nil : highlights
        }
        for key in ["result", "data", "response", "checkResponse"] {
            if let nested = json[key] as? [String: Any],
               let nestedHighlights = Self.extractHighlights(from: nested) {
                return nestedHighlights
            }
        }
        return nil
    }

    private static func extractPracticeProblem(from json: [String: Any]) -> ElaraPracticeProblem? {
        if let practiceObject = (json["practice_problem"] as? [String: Any]) ?? (json["practiceProblem"] as? [String: Any]) {
            let problemText = Self.firstString(in: practiceObject, keys: ["problem_text", "problemText"])
            guard let problemText else {
                return nil
            }
            return ElaraPracticeProblem(problemText: problemText,
                                        topic: Self.firstString(in: practiceObject, keys: ["topic"]),
                                        difficulty: Self.firstString(in: practiceObject, keys: ["difficulty"]),
                                        hints: Self.stringArray(in: practiceObject, keys: ["hints"]) ?? [],
                                        sourceSnapshotId: Self.firstString(in: practiceObject, keys: ["source_snapshot_id", "sourceSnapshotId"]))
        }
        for key in ["result", "data", "response", "checkResponse"] {
            if let nested = json[key] as? [String: Any],
               let nestedPractice = Self.extractPracticeProblem(from: nested) {
                return nestedPractice
            }
        }
        return nil
    }

    private static func stringArray(in json: [String: Any], keys: [String]) -> [String]? {
        for key in keys {
            if let values = json[key] as? [String] {
                return values
            }
            if let values = json[key] as? [Any] {
                let strings = values.compactMap { $0 as? String }
                if strings.isEmpty == false {
                    return strings
                }
            }
        }
        return nil
    }

    private static func firstInt(in json: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = json[key] as? Int {
                return value
            }
            if let value = json[key] as? NSNumber {
                return value.intValue
            }
        }
        return nil
    }

    private static func parseBBox(from rawBBox: [String: Any]) -> ElaraBBox? {
        guard let x = Self.doubleValue(from: rawBBox["x"]),
              let y = Self.doubleValue(from: rawBBox["y"]),
              let width = Self.doubleValue(from: rawBBox["width"]),
              let height = Self.doubleValue(from: rawBBox["height"]) else {
            return nil
        }
        return ElaraBBox(x: x, y: y, width: width, height: height)
    }

    private static func doubleValue(from any: Any?) -> Double? {
        if let number = any as? NSNumber {
            return number.doubleValue
        }
        if let value = any as? Double {
            return value
        }
        if let value = any as? Float {
            return Double(value)
        }
        if let value = any as? Int {
            return Double(value)
        }
        return nil
    }

    private static func logAnalyzeRequest(_ request: ElaraAnalyzeRequest) {
        if let transcriptionText = request.recognition.transcriptionText, transcriptionText.isEmpty == false {
            print("[Elara Analyze] Transcription:")
            print(transcriptionText)
        } else {
            print("[Elara Analyze] Transcription: <none>")
        }
        if let steps = request.recognition.provisionalSteps, steps.isEmpty == false {
            print("[Elara Analyze] Provisional steps count: \(steps.count)")
            for step in steps.prefix(8) {
                let bboxString: String
                if let bbox = step.bbox {
                    bboxString = "(\(bbox.x), \(bbox.y), \(bbox.width), \(bbox.height))"
                } else {
                    bboxString = "<none>"
                }
                print("[Elara Analyze] Step[\(step.lineIndex)] \(step.elementType): \(step.text) | bbox=\(bboxString) | strokes=\(step.strokeIds.count)")
            }
        } else {
            print("[Elara Analyze] Provisional steps: <none>")
        }
        if let wordLocations = request.recognition.wordLocations, wordLocations.isEmpty == false {
            print("[Elara Analyze] Word locations count: \(wordLocations.count)")
            let preview = wordLocations.prefix(12)
            for word in preview {
                let coords = [word.x, word.y, word.width, word.height].map { value -> String in
                    guard let value else { return "nil" }
                    return String(format: "%.2f", value)
                }.joined(separator: ", ")
                print("[Elara Analyze] \(word.label) @ (\(coords))")
            }
        } else {
            print("[Elara Analyze] Word locations: <none>")
        }
        let verboseRecognitionLogs = (Bundle.main.object(forInfoDictionaryKey: "ELARA_LOG_VERBOSE_RECOGNITION") as? Bool) ?? false
        if verboseRecognitionLogs,
           let wordLocations = request.recognition.wordLocations, wordLocations.isEmpty == false {
            let preview = wordLocations.prefix(12)
            for word in preview {
                print("[Elara Analyze][verbose] \(word.label) candidates=\(word.candidates ?? []) strokeIds=\(word.strokeIds ?? [])")
            }
        }
        print("[Elara Analyze] Client meta: canvas=\(request.clientMeta.canvasWidth)x\(request.clientMeta.canvasHeight) scale=\(request.clientMeta.viewScale) offset=(\(request.clientMeta.viewOffsetX), \(request.clientMeta.viewOffsetY)) space=\(request.clientMeta.coordinateSpace)")
        if let canvasImage = request.canvasImage {
            print("[Elara Analyze] Canvas image: mime=\(canvasImage.mimeType) ext=\(canvasImage.fileExtension) size=\(canvasImage.width ?? -1)x\(canvasImage.height ?? -1) base64Bytes=\(canvasImage.dataBase64.count)")
        } else {
            print("[Elara Analyze] Canvas image: <none>")
        }
        print("[Elara Analyze] Payload summary: requestId=\(request.requestId), snapshotId=\(request.snapshotId), lastSnapshotId=\(request.lastSnapshotId ?? "<none>"), partId=\(request.document.partId), partType=\(request.document.partType), mime=\(request.recognition.mimeType), rawJiixBytes=\(request.recognition.rawJiix?.count ?? 0), rawDataBase64Bytes=\(request.exportedDataBase64?.count ?? 0)")
        let shouldLogFullPayload = (Bundle.main.object(forInfoDictionaryKey: "ELARA_LOG_FULL_PAYLOAD") as? Bool) ?? false
        if shouldLogFullPayload,
           let encoded = try? JSONEncoder().encode(request),
           let payloadString = String(data: encoded, encoding: .utf8) {
            print("[Elara Analyze] JSON payload:")
            print(payloadString)
        }
    }
}
