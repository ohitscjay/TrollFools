//
//  AppListView.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import CocoaLumberjackSwift
import Combine
import SwiftUI

final class App: Identifiable, ObservableObject {
    let id: String
    let name: String
    let type: String
    let teamID: String
    let url: URL
    let version: String?
    let dataurl: URL
    
    @Published var isDetached: Bool = false
    @Published var isAllowedToAttachOrDetach: Bool
    @Published var isInjected: Bool = false
    
    lazy var icon: UIImage? = UIImage._applicationIconImage(forBundleIdentifier: id, format: 0, scale: 3.0)
    var alternateIcon: UIImage?
    
    lazy var isUser: Bool = type == "User"
    lazy var isSystem: Bool = !isUser
    lazy var isFromApple: Bool = id.hasPrefix("com.apple.")
    lazy var isFromTroll: Bool = isSystem && !isFromApple
    lazy var isRemovable: Bool = url.path.contains("/var/containers/Bundle/Application/")
    
    init(id: String,
         name: String,
         type: String,
         teamID: String,
         url: URL,
         version: String? = nil,
         alternateIcon: UIImage? = nil,
         dataurl: URL
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.teamID = teamID
        self.url = url
        self.version = version
        self.isDetached = Injector.isBundleDetached(url)
        self.isAllowedToAttachOrDetach = type == "User" && Injector.isBundleAllowedToAttachOrDetach(url)
        self.isInjected = Injector.isBundleInjected(url)
        self.alternateIcon = alternateIcon
        self.dataurl = dataurl
    }
    
    func reload() {
        reloadDetachedStatus()
        reloadInjectedStatus()
    }
    
    private func reloadDetachedStatus() {
        self.isDetached = Injector.isBundleDetached(url)
        self.isAllowedToAttachOrDetach = isUser && Injector.isBundleAllowedToAttachOrDetach(url)
    }
    
    private func reloadInjectedStatus() {
        self.isInjected = Injector.isBundleInjected(url)
    }
}

enum SortOrder {
    case ascending
    case descending
}

final class AppListModel: ObservableObject {
    static let shared = AppListModel()
    static let hasTrollStore: Bool = { LSApplicationProxy(forIdentifier: "com.opa334.TrollStore") != nil }()
    private var _allApplications: [App] = []
    
    @Published var filter = FilterOptions()
    @Published var userApplications: [App] = []
    @Published var trollApplications: [App] = []
    @Published var appleApplications: [App] = []
    
    @Published var hasTrollRecorder: Bool = false
    @Published var unsupportedCount: Int = 0
    
    @Published var isFilzaInstalled: Bool = false
    private let filzaURL = URL(string: "filza://")
    
    @Published var isRebuildNeeded: Bool = false
    @Published var isRebuilding: Bool = false
    @Published var selectedFilter: Filter = .all
    
    
    enum Filter: String, CaseIterable {
        case all = "AllApps"
        case user = "UserApps"
        case troll = "TrollApps"
        case system = "SysApps"
    }
    
    private let applicationChanged = PassthroughSubject<Void, Never>()
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        reload()
        
        filter.$searchKeyword
            .combineLatest(filter.$showPatchedOnly)
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                withAnimation {
                    self?.performFilter()
                }
            }
            .store(in: &cancellables)
        
        applicationChanged
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                withAnimation {
                    self?.reload()
                }
            }
            .store(in: &cancellables)
        
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(darwinCenter, Unmanaged.passRetained(self).toOpaque(), { center, observer, name, object, userInfo in
            guard let observer = Unmanaged<AppListModel>.fromOpaque(observer!).takeUnretainedValue() as AppListModel? else {
                return
            }
            observer.applicationChanged.send()
        }, "com.apple.LaunchServices.ApplicationsChanged" as CFString, nil, .coalesce)
    }
    
    func reload() {
        let allApplications = Self.fetchApplications(&hasTrollRecorder, &unsupportedCount)
        self._allApplications = allApplications
        if let filzaURL {
            self.isFilzaInstalled = UIApplication.shared.canOpenURL(filzaURL)
        } else {
            self.isFilzaInstalled = false
        }
        performFilter()
    }
    
    @Published var sortOrder: SortOrder = .ascending
    
    func performFilter() {
        var filteredApplications = _allApplications
        
        if !filter.searchKeyword.isEmpty {
            filteredApplications = filteredApplications.filter {
                $0.name.localizedCaseInsensitiveContains(filter.searchKeyword) || $0.id.localizedCaseInsensitiveContains(filter.searchKeyword)
            }
        }
        
        if filter.showPatchedOnly {
            filteredApplications = filteredApplications.filter { $0.isInjected }
        }
        
        switch selectedFilter {
        case .all:
            break
        case .user:
            filteredApplications = filteredApplications.filter { $0.isUser }
        case .troll:
            filteredApplications = filteredApplications.filter { $0.isFromTroll }
        case .system:
            filteredApplications = filteredApplications.filter { $0.isFromApple }
        }
        
        filteredApplications.sort { sortOrder == .ascending ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        
        userApplications = filteredApplications.filter { $0.isUser }
        trollApplications = filteredApplications.filter { $0.isFromTroll }
        appleApplications = filteredApplications.filter { $0.isFromApple }
    }
    
    private static let excludedIdentifiers: Set<String> = [
        "com.opa334.Dopamine",
        "org.coolstar.SileoStore",
    ]
    
    private static func fetchApplications(_ hasTrollRecorder: inout Bool, _ unsupportedCount: inout Int) -> [App] {
        let allApps: [App] = LSApplicationWorkspace.default()
            .allApplications()
            .compactMap { proxy in
                guard let id = proxy.applicationIdentifier(),
                      let url = proxy.bundleURL(),
                      let teamID = proxy.teamID(),
                      let appType = proxy.applicationType(),
                      let localizedName = proxy.localizedName(),
                      let dataurl = proxy.dataContainerURL()
                else {
                    return nil
                }
                
                if id == "wiki.qaq.trapp" {
                    hasTrollRecorder = true
                }
                
                guard !id.hasPrefix("wiki.qaq.") && !id.hasPrefix("com.82flex.") else {
                    return nil
                }
                
                guard !excludedIdentifiers.contains(id) else {
                    return nil
                }
                
                let shortVersionString: String? = proxy.shortVersionString()
                let app = App(
                    id: id,
                    name: localizedName,
                    type: appType,
                    teamID: teamID,
                    url: url,
                    version: shortVersionString,
                    dataurl: dataurl
                )
                
                if app.isUser && app.isFromApple {
                    return nil
                }
                
                guard app.isRemovable else {
                    return nil
                }
                
                return app
            }
        
        let filteredApps = allApps
            .filter { $0.isSystem || Injector.isBundleEligible($0.url) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        unsupportedCount = allApps.count - filteredApps.count
        
        return filteredApps
    }
    
    func openInFilza(_ url: URL) {
        guard let filzaURL else {
            return
        }
        let fileURL = filzaURL.appendingPathComponent(url.path)
        UIApplication.shared.open(fileURL)
    }
    
    func rebuildIconCache() throws {
        // Sadly, we can't call `trollstorehelper` directly because only TrollStore can launch it without error.
        LSApplicationWorkspace.default().openApplication(withBundleID: "com.opa334.TrollStore")
    }
}

final class FilterOptions: ObservableObject {
    @Published var searchKeyword = ""
    @Published var showPatchedOnly = false
    
    var isSearching: Bool { !searchKeyword.isEmpty }
    
    func reset() {
        searchKeyword = ""
        showPatchedOnly = false
    }
}

struct AppListCell: View {
    @StateObject var app: App
    @EnvironmentObject var filter: FilterOptions
    
    @available(iOS 15.0, *)
    var highlightedName: AttributedString {
        let name = app.name
        var attributedString = AttributedString(name)
        if let range = attributedString.range(of: filter.searchKeyword, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributedString[range].foregroundColor = .accentColor
        }
        return attributedString
    }
    
    @available(iOS 15.0, *)
    var highlightedId: AttributedString {
        let id = app.id
        var attributedString = AttributedString(id)
        if let range = attributedString.range(of: filter.searchKeyword, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributedString[range].foregroundColor = .accentColor
        }
        return attributedString
    }
    
    @ViewBuilder
    var cellContextMenu: some View {
        
        Button {
            launch()
        } label: {
            Label(NSLocalizedString("Launch", comment: ""), systemImage: "command")
        }
        
        if isFilzaInstalled {
            Button {
                openInFilza()
            } label: {
                Label(NSLocalizedString("Show in Filza", comment: ""), systemImage: "scope")
            }
        }
        
        if AppListModel.hasTrollStore && app.isAllowedToAttachOrDetach {
            if app.isDetached {
                Button {
                    do {
                        let injector = try Injector(app.url, appID: app.id, teamID: app.teamID)//MARK
                        try injector.setDetached(false)
                        withAnimation(.easeInOut(duration: 0.5).delay(0.2)) {
                            app.reload()
                            AppListModel.shared.isRebuildNeeded = true
                        }

                    } catch { DDLogError("\(error.localizedDescription)") }
                } label: {
                    Label(NSLocalizedString("Unlock Version", comment: ""), systemImage: "lock.open")
                }
            } else {
                Button {
                    do {
                        let injector = try Injector(app.url, appID: app.id, teamID: app.teamID)
                        try injector.setDetached(true)
                        withAnimation {
                            app.reload()
                            AppListModel.shared.isRebuildNeeded = true
                        }
                    } catch { DDLogError("\(error.localizedDescription)") }
                } label: {
                    Label(NSLocalizedString("Lock Version", comment: ""), systemImage: "lock")
                }
            }
            Button {
                clearCaches()
            } label: {
                Label(NSLocalizedString("Clear Caches", comment: ""), systemImage: "trash")
            }
        }
    }
    
    @ViewBuilder
    var cellContextMenuWrapper: some View {
        if #available(iOS 16.0, *) {
            // iOS 16
            cellContextMenu
        } else {
            if #available(iOS 15.0, *) { }
            else {
                // iOS 14
                cellContextMenu
            }
        }
    }
    
    @ViewBuilder
    var cellBackground: some View {
        if #available(iOS 15.0, *) {
            if #available(iOS 16.0, *) { }
            else {
                // iOS 15
                Color.clear
                    .contextMenu { cellContextMenu }
                    .id(app.isDetached)
            }
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: app.alternateIcon ?? app.icon ?? UIImage())
                .resizable()
                .frame(width: 32, height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if #available(iOS 15.0, *) {
                        Text(highlightedName)
                            .font(.headline)
                            .lineLimit(1)
                    } else {
                        Text(app.name)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    
                    if app.isInjected {
                        Image(systemName: "bandage")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .accessibilityLabel(NSLocalizedString("Patched", comment: ""))
                    }
                }
                
                if #available(iOS 15.0, *) {
                    Text(highlightedId)
                        .font(.subheadline)
                        .lineLimit(1)
                } else {
                    Text(app.id)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if let version = app.version {
                if app.isUser && app.isDetached {
                    HStack(spacing: 4) {
                        Image(systemName: "lock")
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .accessibilityLabel(NSLocalizedString("Pinned Version", comment: ""))
                        
                        Text(version)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(version)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contextMenu { cellContextMenuWrapper }
        .background(cellBackground)
    }
    
    private func launch() {
        LSApplicationWorkspace.default().openApplication(withBundleID: app.id)
    }
    
    private func clearCaches() {
        let fileManager = FileManager.default

        do {
            let cachesURL = app.dataurl.appendingPathComponent("Library/Caches")
            let tmpURL = app.dataurl.appendingPathComponent("tmp")

            let cacheFiles = try fileManager.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: nil)
            for file in cacheFiles {
                try fileManager.removeItem(at: file)
            }

            let tmpFiles = try fileManager.contentsOfDirectory(at: tmpURL, includingPropertiesForKeys: nil)
            for file in tmpFiles {
                try fileManager.removeItem(at: file)
            }

            let alertTitle = NSLocalizedString("Notification", comment: "")
            let alertMessage = NSLocalizedString("Clear Done", comment: "")
            let alert = UIAlertController(title: alertTitle, message: alertMessage, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default, handler: nil))

            DispatchQueue.main.async {
                if let topController = UIApplication.shared.windows.first?.rootViewController {
                    topController.present(alert, animated: true, completion: nil)
                }
            }
        } catch {
            // Handle error if needed
        }
    }

    
    var isFilzaInstalled: Bool { AppListModel.shared.isFilzaInstalled }
    
    private func openInFilza() {
        AppListModel.shared.openInFilza(app.url)
    }
}

struct AppListView: View {
    @StateObject var vm = AppListModel.shared
    @State private var isUsingOfficialIcon = false
    @State private var showSearchBar = false
    @State private var searchText: String = ""
    @State var isErrorOccurred: Bool = false
    @State var errorMessage: String = ""
    @State private var showTAlert = false
    @State var inputPath: String = ""
    @State private var receivedURL: URL?
    
    
    
    
    let filters: [AppListModel.Filter] = AppListModel.Filter.allCases
    
    
    var appNameString: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "TrollFools"
    }
    
    var appVersionString: String {
        String(format: "v%@ (%@)",
               Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
               Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")
    }
    
    var appString: String {
        String(format: """
    %@ %@ %@ © 2024
    %@
    %@
    %@
    """, appNameString, appVersionString, NSLocalizedString("Copyright", comment: ""), NSLocalizedString("Lessica, Lakr233, mlgm and other contributors.", comment: ""),
               NSLocalizedString("huami Add some features", comment: ""),"TG：@huamidev")
    }
    
    let repoURL = URL(string: "https://github.com/Lessica/TrollFools")
    
    func filteredAppList(_ apps: [App]) -> some View {
        ForEach(apps, id: \.id) { app in
            NavigationLink {
                OptionView(app, inputPath)
                    .onDisappear {
                        inputPath = ""                }
            } label: {
                if #available(iOS 16.0, *) {
                    AppListCell(app: app)
                        .environmentObject(vm.filter)
                } else {
                    AppListCell(app: app)
                        .environmentObject(vm.filter)
                        .padding(.vertical, 4)
                }
            }
        }
    }
    
    
    var appListFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appString)
                .font(.footnote)
            
            Button {
                guard let url = repoURL else {
                    return
                }
                UIApplication.shared.open(url)
            } label: {
                Text(NSLocalizedString("Source Code", comment: ""))
                    .font(.footnote)
            }
        }
    }
    
    var appList: some View {
        
        List {
            if AppListModel.hasTrollStore && vm.isRebuildNeeded {
                Section {
                    Button {
                        rebuildIconCache()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(NSLocalizedString("Rebuild Icon Cache", comment: ""))
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                
                                Text(NSLocalizedString("You need to rebuild the icon cache in TrollStore to apply changes.", comment: ""))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if vm.isRebuilding {
                                if #available(iOS 16.0, *) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .controlSize(.large)
                                } else {
                                    // Fallback on earlier versions
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .scaleEffect(2.0)
                                }
                            } else {
                                Image(systemName: "timelapse")
                                    .font(.title)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(vm.isRebuilding)
                }
            }
            
            Section {
                filteredAppList(vm.userApplications)
                filteredAppList(vm.trollApplications)
                filteredAppList(vm.appleApplications)
            } footer: {
                if !vm.filter.isSearching {
                    VStack(alignment: .leading, spacing: 20) {
                        if !vm.filter.showPatchedOnly {
                            Text(NSLocalizedString("Only removable system applications are eligible and listed.", comment: ""))
                                .font(.footnote)
                        }
                        
                        if #available(iOS 16.0, *) {
                            appListFooter
                                .padding(.top, 8)
                        } else {
                            appListFooter
                                .padding(.top, 2)
                        }
                    }
                }
            }
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.width < 0 {
                        if let currentIndex = filters.firstIndex(of: vm.selectedFilter) {
                            vm.selectedFilter = filters[(currentIndex + 1) % filters.count]
                        }
                    } else if value.translation.width > 0 {
                        if let currentIndex = filters.firstIndex(of: vm.selectedFilter) {
                            vm.selectedFilter = filters[(currentIndex - 1 + filters.count) % filters.count]
                        }
                    }
                }
        )
        .listStyle(.insetGrouped)
        .navigationTitle(NSLocalizedString("TrollFools", comment: ""))
        .background(Group {
            NavigationLink(isActive: $isErrorOccurred) {
                FailureView(title: NSLocalizedString("Error", comment: ""),
                            message: errorMessage)
            } label: { }
        })
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button(NSLocalizedString("Name (A-Z)", comment: "")) {
                        vm.sortOrder = .ascending
                        vm.performFilter()
                    }
                    Button(NSLocalizedString("Name (Z-A)", comment: "")) {
                        vm.sortOrder = .descending
                        vm.performFilter()
                    }
                    Button(action: toggleAppIcon) {
                        Text(isUsingOfficialIcon ? NSLocalizedString("Switch to Default Icon", comment: "") : NSLocalizedString("Switch to Official Icon", comment: ""))
                    }
                    Button(action: clearCache) {
                        Text(NSLocalizedString("Clear App Cache", comment: ""))
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
                .accessibilityLabel(NSLocalizedString("Sort Order", comment: ""))
                
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    vm.filter.showPatchedOnly.toggle()
                }) {
                    Image(systemName: vm.filter.showPatchedOnly
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(NSLocalizedString("Show Patched Only", comment: ""))
            }
        }
        .onChange(of: vm.sortOrder) { _ in
            vm.performFilter()
        }
        .onAppear {
            vm.reload()
            checkCurrentIcon()
        }
    }
    private func clearCache() {
        let fileManager = FileManager.default
        
        let tmpURL = fileManager.temporaryDirectory
        do {
            let tmpContents = try fileManager.contentsOfDirectory(at: tmpURL, includingPropertiesForKeys: nil)
            for file in tmpContents {
                try fileManager.removeItem(at: file)
            }
        } catch {}
        
        let inboxURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Inbox")
        do {
            let inboxContents = try fileManager.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)
            for file in inboxContents {
                try fileManager.removeItem(at: file)
            }
        } catch {}
        
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        do {
            let cacheContents = try fileManager.contentsOfDirectory(at: cachesDirectory, includingPropertiesForKeys: nil)
            for file in cacheContents {
                try fileManager.removeItem(at: file)
            }
        } catch {}
        
        let alertTitle = NSLocalizedString("Notification", comment: "")
        let alertMessage = NSLocalizedString("Clear Done", comment: "")
        let alert = UIAlertController(title: alertTitle, message: alertMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default, handler: nil))
        
        DispatchQueue.main.async {
            if let topController = UIApplication.shared.windows.first?.rootViewController {
                topController.present(alert, animated: true, completion: nil)
            }
        }
    }
    
    
    private func toggleAppIcon() {
        let newIcon = isUsingOfficialIcon ? nil : "AppIcon-official"
        
        UIApplication.shared.setAlternateIconName(newIcon) { error in
            if let error = error {
                print("Failed to set icon: \(error)")
            }
        }
        
        isUsingOfficialIcon.toggle()
    }
    
    private func checkCurrentIcon() {
        let currentIconName = UIApplication.shared.alternateIconName
        DispatchQueue.main.async {
            self.isUsingOfficialIcon = (currentIconName == "AppIcon-official")
        }
    }
    
    @State private var isEditing = false
    @State private var isFirstLaunch: Bool = false
    var body: some View {
        NavigationView {
            VStack {
                //                if #available(iOS 14.0, *) {
                //                    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17 {
                HStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                            .padding(10)
                            .background(Color(.systemGray6))
                            .cornerRadius(6)
                        TextField("Search…", text: $searchText, onEditingChanged: { editing in
                            withAnimation {
                                isEditing = editing
                            }
                        })
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                    .frame(maxWidth: isEditing ? .infinity : .infinity)
                    //                    .animation(.easeInOut)
                    if isEditing {
                        Button(action: {
                            withAnimation {
                                searchText = ""
                                isEditing = false
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            }
                        }) {
                            Text(NSLocalizedString("Cancel", comment: ""))
                                .foregroundColor(.blue)
                                .padding(2)
                        }
                        .transition(.move(edge: .trailing))
                        .frame(width: 60)
                    }
                }
                .padding(.horizontal)
                //                    }
                //                }
//                Spacer(minLength: 20)
                Picker("", selection: $vm.selectedFilter) {
                    Text(NSLocalizedString("All", comment: "")).tag(AppListModel.Filter.all)
                    Text(NSLocalizedString("User", comment: "")).tag(AppListModel.Filter.user)
                    Text(NSLocalizedString("Troll", comment: "")).tag(AppListModel.Filter.troll)
                    Text(NSLocalizedString("System", comment: "")).tag(AppListModel.Filter.system)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .padding(.vertical, 4)
                .onChange(of: vm.selectedFilter) { newValue in
                    withAnimation {
                        vm.performFilter()
                    }
                }
                appList
                    .padding(.top, 4)
                    .onAppear {
                        vm.filter.searchKeyword = searchText
                    }
                    .onChange(of: searchText) { newValue in
                        vm.filter.searchKeyword = newValue
                        vm.performFilter()
                    }
            }
            .onOpenURL { url in
                if url.isFileURL {
                    if url.pathExtension == "dylib" {
                        showTAlert = true
                        receivedURL = url
                    } else {
                        if url.pathExtension == "deb" {
                            let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                            showTAlert = true
                            let decomposer = DebDecomposer()
                            receivedURL = decomposer.decomposeDeb(at: url, to: cachesDirectory)
                        }
                    }
                }
            }
            .alert(isPresented: $showTAlert) {
                Alert(
                    title: Text(NSLocalizedString("You imported a file", comment: "")),
                    message: Text(NSLocalizedString("What would you like to do?\nSelect 'Inject' to choose the app for injection.\nSelect 'Do Nothing' to cancel.", comment: "")),
                    primaryButton: .default(Text(NSLocalizedString("Inject", comment: ""))) {
                        if let path = receivedURL?.path {
                            inputPath = path
                        }
                    },
                    secondaryButton: .cancel(Text(NSLocalizedString("Do Nothing", comment: ""))) {
                        inputPath = ""
                    }
                )
            }
        }
        .onAppear {
            checkFirstLaunch()
        }
        .alert(isPresented: $isFirstLaunch) {
                    Alert(
                        title: Text("Notification"),
                        message: Text("This software is an open-source project TrollFools.\nIf you have purchased it, you should understand what this means.\nVisit the project address in the footer for more information.\nModified version by huami.\nChange Lessica to huami1314 to redirect to this project.\nTG: @huamidev\nThis popup will only display once.\nThanks to the original author i_82.")
                                .font(.subheadline),
                        dismissButton: .default(Text("OK"))
                    )
                }
    }
    
    
    private func checkFirstLaunch() {
        let fileManager = FileManager.default
        let lockFilePath = getDocumentsDirectory().appendingPathComponent(".launch.lock")
        
        if !fileManager.fileExists(atPath: lockFilePath.path) {
            fileManager.createFile(atPath: lockFilePath.path, contents: nil, attributes: nil)
            isFirstLaunch = true
            showLaunchAlert()
        } else {
            isFirstLaunch = false
        }
    }

    private func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private func showLaunchAlert() {
    }


    
    private func goToNextFilter() {
        if let currentIndex = filters.firstIndex(of: vm.selectedFilter), currentIndex < filters.count - 1 {
            vm.selectedFilter = filters[currentIndex + 1]
        }
    }
    
    private func goToPreviousFilter() {
        if let currentIndex = filters.firstIndex(of: vm.selectedFilter), currentIndex > 0 {
            vm.selectedFilter = filters[currentIndex - 1]
        }
    }
    
    private func rebuildIconCache() {
        withAnimation {
            vm.isRebuilding = true
        }
        
        DispatchQueue.global(qos: .userInteractive).async {
            defer {
                DispatchQueue.main.async {
                    withAnimation {
                        vm.isRebuilding = false
                    }
                }
            }
            
            do {
                try vm.rebuildIconCache()
                
                DispatchQueue.main.async {
                    withAnimation {
                        vm.isRebuildNeeded = false
                    }
                }
            } catch {
                DDLogError("\(error.localizedDescription)")
                
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    isErrorOccurred = true
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        AppListView()
    }
}

