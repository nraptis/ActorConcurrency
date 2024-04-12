//
//  CommunityViewModel.swift
//  BlockchainMoviesApp
//
//  Created by Nicky Taylor on 4/9/24.
//

import SwiftUI
import BlockChainNetworking
import BlockChainDatabase
import Combine

@globalActor actor DatabaseActor {
    //
    // This actor shouldn't be necessary as we
    // are already using context.perform for the transactions.
    //
    // I am leaving it because it seems more proper; this way,
    // have a single execution channel for any db transactions.
    // we could add calls without perform blocks, or swap the backing
    // technology and wouldn't have to refactor this code.
    //
    static let shared = DatabaseActor()
}

@Observable class CommunityViewModel {
    
    typealias NWMovie = BlockChainNetworking.NWMovie
    typealias DBMovie = BlockChainDatabase.DBMovie
    
    private static let probeAheadOrBehindRangeForDownloads = 8
    
    static func mock() -> CommunityViewModel {
        return CommunityViewModel()
    }
    
    // BAD! We don't do ownership this way. The view model
    // will broadcast messages, e.g. subscribers to the listeners.
    //@ObservationIgnored weak var movieGridView: MovieGridView?
    
    @ObservationIgnored @DatabaseActor private var databaseController = BlockChainDatabase.DatabaseController()
    
    @ObservationIgnored private let downloader = DirtyImageDownloader(numberOfSimultaneousDownloads: 2)
    
    @MainActor @ObservationIgnored fileprivate var _imageDict = [String: UIImage]()
    
    @MainActor @ObservationIgnored fileprivate var _imageFailedSet = Set<Int>()
    @MainActor @ObservationIgnored fileprivate var _imageDownloadingActivelySet = Set<Int>()
    @MainActor @ObservationIgnored fileprivate var _imageDownloadingSet = Set<Int>()
    @MainActor @ObservationIgnored fileprivate var _imageDidCheckCacheSet = Set<Int>()
    
    @MainActor @ObservationIgnored private var _addDownloadItems = [CommunityCellModel]()
    @MainActor @ObservationIgnored private var _checkCacheDownloadItems = [CommunityCellModel]()
    @MainActor @ObservationIgnored private var _checkCacheKeys = [KeyAndIndexPair]()
    
    
    @MainActor @ObservationIgnored var isUsingDatabaseData = false
    
    @ObservationIgnored var isAssigningTasksToDownloader = false
    @ObservationIgnored var isAssigningTasksToDownloaderEnqueued = false
    
    @ObservationIgnored var pageSize = 0
    
    @ObservationIgnored var numberOfItems = 0
    
    @ObservationIgnored var numberOfCells = 0
    @ObservationIgnored var numberOfPages = 0
    
    @ObservationIgnored var highestPageFetchedSoFar = 0
    
    @ObservationIgnored private var _priorityCommunityCellModels = [CommunityCellModel]()
    @ObservationIgnored private var _priorityList = [Int]()
    
    @ObservationIgnored let layout = GridLayout()
    @ObservationIgnored private let imageCache = DirtyImageCache(name: "dirty_cache")
    @ObservationIgnored private(set) var isRefreshing = false
    
    @MainActor private(set) var isFetching = false
    @MainActor private(set) var isNetworkErrorPresent = false
    @MainActor var isAnyItemPresent = false
    
    @ObservationIgnored let cellNeedsUpdatePublisher = PassthroughSubject<Int, Never>()
    @ObservationIgnored let layoutFrameWidthUpdatePublisher = PassthroughSubject<CGFloat, Never>()
    @ObservationIgnored let layoutFrameHeightUpdatePublisher = PassthroughSubject<CGFloat, Never>()
    @ObservationIgnored let visibleCellsUpdatePublisher = PassthroughSubject<[GridLayout.ThumbGridCellModel], Never>()
    
    init() {
        
        downloader.delegate = self
        downloader.isBlocked = true
        
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil,
                                               queue: nil) { notification in
            print("Memory Warning!!! Purging RAM Images...")
            
            Task { @MainActor in
                self._imageDict.removeAll(keepingCapacity: true)
                self._imageFailedSet.removeAll(keepingCapacity: true)
                self._imageDidCheckCacheSet.removeAll(keepingCapacity: true)
            }
        }
        
        // In this case, it doesn't matter the order that the imageCache and dataBase load,
        // however, we want them to both load before the network call fires.
        
        Task { @MainActor in
            layout.delegate = self
            
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @DirtyImageCacheActor in
                    self.imageCache.load()
                }
                group.addTask { @DatabaseActor in
                    await self.databaseController.loadPersistentStores()
                }
            }
            downloader.isBlocked = false
            await fetchPopularMovies(page: 1)
        }
    }
    
    @MainActor func refresh() async {
        
        if isRefreshing {
            print("🧚🏽 We are already refreshing... No double refreshing...!!!")
            return
        }
        
        isRefreshing = true
        
        downloader.isBlocked = true
        await downloader.cancelAll()
        
        var fudge = 0
        
        while isFetching {
            if fudge == 0 {
                print("🙅🏽‍♀️ Refreshing During Fetch... Waiting For End!!!")
            }
            
            try? await Task.sleep(nanoseconds: 1_000_000)
            
            fudge += 1
            if fudge >= 2048 {
                print("🧛🏻‍♂️ Terminating refresh, we are fetch-locked.")
                downloader.isBlocked = false
                isRefreshing = false
                return
            }
        }
        
        let nwMovies = await _fetchPopularMoviesWithNetwork(page: 1)
        
        // This is mainly just for user feedback; the refresh feels
        // more natural if it takes a couple seconds...
        try? await Task.sleep(nanoseconds: 1_250_000_000)
        
        if nwMovies.count <= 0 {
            print("🧟‍♀️ Bad Refresh! We got no items from the network...")
            
            let dbMovies = await _fetchPopularMoviesWithDatabase()
            if dbMovies.count <= 0 {
                print("🧟‍♀️ Bad Refresh! We got no items from the database...")
                
                downloader.isBlocked = false
                isRefreshing = false
                isAnyItemPresent = false
            } else {
                
                pageSize = -1
                numberOfItems = dbMovies.count
                numberOfCells = dbMovies.count
                numberOfPages = -1
                highestPageFetchedSoFar = -1
                isUsingDatabaseData = true
                _clearForRefresh()
                _synchronize(dbMovies: dbMovies)
                downloader.isBlocked = false
                isRefreshing = false
                layout.registerNumberOfCells(numberOfCells)
                handleCellsMayHaveChanged()
                isAnyItemPresent = true
            }
        } else {
            isUsingDatabaseData = false
            _clearForRefresh()
            _synchronize(nwMovies: nwMovies, page: 0)
            downloader.isBlocked = false
            isRefreshing = false
            layout.registerNumberOfCells(numberOfCells)
            handleCellsMayHaveChanged()
            isAnyItemPresent = true
        }
    }
    
    @MainActor func _clearForRefresh() {
        
        // Empty out all the internal storage crap...!!!
        _imageDict.removeAll()
        _imageFailedSet.removeAll()
        _imageDownloadingActivelySet.removeAll()
        _imageDownloadingSet.removeAll()
        _imageDidCheckCacheSet.removeAll()
        
        layout.clear()
        
        for communityCellModel in communityCellModels {
            if let communityCellModel = communityCellModel {
                _depositCommunityCellModel(communityCellModel)
            }
        }
        communityCellModels.removeAll()
    }
    
    @MainActor func fetchPopularMovies(page: Int) async {
        
        print("🪅 Fetch Movies @ \(page)!!!")
        
        if isFetching {
            print("🎳 Already fetching, preventing double fetch on page \(page)!")
            return
        }
        
        if isRefreshing {
            print("🎳 We are REFRESHING, cancel the fetch on page \(page)!")
            return
        }
        
        print("fetching page \(page)")
        isFetching = true
        
        let nwMovies = await _fetchPopularMoviesWithNetwork(page: page)
        
        // We either fetched nothing, or got an error.
        if nwMovies.count <= 0 {
            if communityCellModels.count > 0 {
                // We will just keep what we have...
            } else {
                
                // We will fetch from the database!!!
                let dbMovies = await _fetchPopularMoviesWithDatabase()
                if dbMovies.count <= 0 {
                    
                    print("🪣 Tried to use database, there are no items.")
                    
                    isUsingDatabaseData = false
                    isAnyItemPresent = false
                
                } else {
                    
                    print("📀 Fetched \(dbMovies.count) items from database! Using offline mode!")
                    
                    pageSize = -1
                    numberOfItems = dbMovies.count
                    numberOfCells = dbMovies.count
                    numberOfPages = -1
                    highestPageFetchedSoFar = -1
                    
                    isUsingDatabaseData = true
                    _synchronize(dbMovies: dbMovies)
                    isAnyItemPresent = true
                }
            }

        } else {
            isUsingDatabaseData = false
            _synchronize(nwMovies: nwMovies, page: page)
            isAnyItemPresent = true
        }
        
        isFetching = false
        layout.registerNumberOfCells(numberOfCells)
        handleCellsMayHaveChanged()
    }
    
    @MainActor private func _synchronize(nwMovies: [NWMovie], page: Int) {
        
        if pageSize <= 0 {
            print("🧌 pageSize = \(pageSize), this seems wrong.")
            return
        }
        if page <= 0 {
            print("🧌 page = \(page), this seems wrong. We expect the pages to start at 1, and number up.")
            return
        }
        
        // The first index of the cells, in the master list.
        let startCellIndex = (page - 1) * pageSize
        var cellModelIndex = startCellIndex
        
        var newCommunityCellModels = [CommunityCellModel]()
        newCommunityCellModels.reserveCapacity(nwMovies.count)
        for nwMovie in nwMovies {
            let cellModel = _withdrawCommunityCellModel(index: cellModelIndex, nwMovie: nwMovie)
            newCommunityCellModels.append(cellModel)
            cellModelIndex += 1
        }
        
        _overwriteCells(newCommunityCellModels, at: startCellIndex)
    }
    
    @MainActor private func _synchronize(dbMovies: [DBMovie]) {
        
        // The first index of the cells, here it's always 0.
        let startCellIndex = 0
        var cellModelIndex = startCellIndex
        
        var newCommunityCellModels = [CommunityCellModel]()
        newCommunityCellModels.reserveCapacity(dbMovies.count)
        for dbMovie in dbMovies {
            let cellModel = _withdrawCommunityCellModel(index: cellModelIndex, dbMovie: dbMovie)
            newCommunityCellModels.append(cellModel)
            cellModelIndex += 1
        }
        
        _magnetizeCells()
        
        _overwriteCells(newCommunityCellModels, at: startCellIndex)
    }
    
    // Put all the cells which were in the communityCellModels
    // list into the queue, blank them all out to nil.
    @MainActor private func _magnetizeCells() {
        var cellModelIndex = 0
        while cellModelIndex < communityCellModels.count {
            if let communityCellModel = communityCellModels[cellModelIndex] {
                _depositCommunityCellModel(communityCellModel)
                communityCellModels[cellModelIndex] = nil
            }
            cellModelIndex += 1
        }
    }
    
    @MainActor private func _overwriteCells(_ newCommunityCellModels: [CommunityCellModel], at index: Int) {
        
        if index < 0 {
            print("🧌 index = \(index), this seems wrong.")
            return
        }
        
        let ceiling = index + newCommunityCellModels.count
        
        // Fill in with blank up to the ceiling
        while communityCellModels.count < ceiling {
            communityCellModels.append(nil)
        }
        
        // What we do here is flush out anything in the range
        // we are "writing" to... In case we have overlap, etc.
        var itemIndex = 0
        var cellModelIndex = index
        while itemIndex < newCommunityCellModels.count {
            if let communityCellModel = communityCellModels[cellModelIndex] {
                _depositCommunityCellModel(communityCellModel)
                communityCellModels[cellModelIndex] = nil
            }
            
            itemIndex += 1
            cellModelIndex += 1
        }

        // What we do here is place new cell models in this range,
        // which will now be 100% clean and ready for that fresh
        // fresh sweet baby Jesus sweeting falling down fast.
        itemIndex = 0
        cellModelIndex = index
        while itemIndex < newCommunityCellModels.count {
            let communityCellModel = newCommunityCellModels[itemIndex]
            communityCellModels[cellModelIndex] = communityCellModel
            itemIndex += 1
            cellModelIndex += 1
        }
    }
    
    private func _fetchPopularMoviesWithNetwork(page: Int) async -> [NWMovie] {
        
        var _isNetworkErrorPresent = false
        
        var result = [NWMovie]()
        do {
            let response = try await BlockChainNetworking.NWNetworkController.fetchPopularMovies(page: page)
            result.append(contentsOf: response.results)
            do {
                try await databaseController.sync(nwMovies: response.results)
                print("💾 We did sync Movies to database.")
            } catch {
                print("🧌 Could not sync Movies to database.")
                print("\(error.localizedDescription)")
            }
            
            numberOfItems = response.total_results
            numberOfPages = response.total_pages
            
            if response.results.count > pageSize { pageSize = response.results.count }
            
            if page > highestPageFetchedSoFar { highestPageFetchedSoFar = page }
            
            var _numberOfCells = (highestPageFetchedSoFar) * pageSize
            if _numberOfCells > numberOfItems { _numberOfCells = numberOfItems }
            
            numberOfCells = _numberOfCells
            
        } catch let error {
            print("🧌 Unable to fetch (Network): \(error.localizedDescription)")
            _isNetworkErrorPresent = true
        }
        
        let __isNetworkErrorPresent = _isNetworkErrorPresent
        await MainActor.run {
            isNetworkErrorPresent = __isNetworkErrorPresent
        }
        
        return result
    }
    
    private func _fetchPopularMoviesWithDatabase() async -> [DBMovie] {
        var result = [DBMovie]()
        do {
            let dbMovies = try await databaseController.fetchMovies()
            result.append(contentsOf: dbMovies)
            
        } catch let error {
            print("🧌 Unable to fetch (Database): \(error.localizedDescription)")
        }
        return result
    }
    
    @MainActor func getCellImage(at index: Int) -> UIImage? {
        if let communityCellModel = getCommunityCellModel(at: index) {
            if let key = communityCellModel.key {
                if let result = _imageDict[key] {
                    return result
                }
            }
        }
        return nil
    }
    
    func forceRestartDownload(at index: Int) {
        fatalError("Not Implemented")
    }
    
    @MainActor func didCellImageDownloadFail(at index: Int) -> Bool {
        _imageFailedSet.contains(index)
    }
    
    @MainActor func isCellImageDownloadActive(at index: Int) -> Bool {
        _imageDownloadingActivelySet.contains(index)
    }
    
    func registerScrollContent(_ scrollContentGeometry: GeometryProxy) {
        Task { @MainActor in
            await assignTasksToDownloader()
        }
    }
    
    @MainActor func handleCellsMayHaveChanged() {
        if layout.isAnyItemPresent {
            isAnyItemPresent = true
        }
        let allVisibleCellModels = layout.getAllVisibleCellModels()
        visibleCellsUpdatePublisher.send(allVisibleCellModels)
        fetchMorePagesIfNecessary()
        Task { @MainActor in
            await assignTasksToDownloader()
        }
    }
    
    @ObservationIgnored @MainActor var communityCellModels = [CommunityCellModel?]()
    @ObservationIgnored @MainActor var cellModelQueue = [CommunityCellModel]()
    
    @MainActor func _withdrawCommunityCellModel(index: Int, nwMovie: BlockChainNetworking.NWMovie) -> CommunityCellModel {
        if cellModelQueue.count > 0 {
            let result = cellModelQueue.removeLast()
            result.inject(index: index, nwMovie: nwMovie)
            return result
        } else {
            let result = CommunityCellModel(index: index, nwMovie: nwMovie)
            return result
        }
    }
    
    @MainActor private func _withdrawCommunityCellModel(index: Int, dbMovie: BlockChainDatabase.DBMovie) -> CommunityCellModel {
        if cellModelQueue.count > 0 {
            let result = cellModelQueue.removeLast()
            result.inject(index: index, dbMovie: dbMovie)
            return result
        } else {
            let result = CommunityCellModel(index: index, dbMovie: dbMovie)
            return result
        }
    }
    
    @MainActor private func _depositCommunityCellModel(_ cellModel: CommunityCellModel) {
        cellModelQueue.append(cellModel)
    }
    
    @MainActor func getCommunityCellModel(at index: Int) -> CommunityCellModel? {
        if index >= 0 && index < communityCellModels.count {
            return communityCellModels[index]
        }
        return nil
    }
    
    // This is on the MainActor because the UI uses "AllVisibleCellModels"
    @MainActor func fetchMorePagesIfNecessary() {
        
        if isFetching { return }
        if isRefreshing { return }
        if isUsingDatabaseData { return }
        
        // They have to pull-to-refresh when the network comes back on...
        if isNetworkErrorPresent { return }
        
        //
        // This needs a valid page size...
        // It sucks they chose "page" instead of (index, limit)
        //
        
        if pageSize < 1 { return }
        
        let allVisibleCellModels = layout.getAllVisibleCellModels()
        
        if allVisibleCellModels.count <= 0 { return }
        
        let numberOfCols = layout.getNumberOfCols()
        
        var _lowest = allVisibleCellModels[0].index
        var _highest = allVisibleCellModels[0].index
        for cellModel in allVisibleCellModels {
            if cellModel.index < _lowest {
                _lowest = cellModel.index
            }
            if cellModel.index > _highest {
                _highest = cellModel.index
            }
        }
        
        _lowest -= numberOfCols
        _highest += (numberOfCols * 4)
        
        if _lowest < 0 {
            _lowest = 0
        }
        
        // These don't change after these lines. Indicated as such with grace.
        let lowest = _lowest
        let highest = _highest
        
        var checkIndex = lowest
        while checkIndex < highest {
            if getCommunityCellModel(at: checkIndex) === nil {
                
                let pageIndexToFetch = (checkIndex / pageSize)
                let pageToFetch = pageIndexToFetch + 1
                
                if pageToFetch < numberOfPages {
                    Task {
                        await fetchPopularMovies(page: pageToFetch)
                    }
                    return
                }
            }
            checkIndex += 1
        }
    }
    
}

// This is for computing download priorities. And image cache.
extension CommunityViewModel {
    
    // Distance from the left of the container / screen.
    // Distance from the top of the container / screen.
    private func priority(distX: Int, distY: Int) -> Int {
        let px = (-distX)
        let py = (8192 * 8192) - (8192 * distY)
        return (px + py)
    }
    
    // If you bunch up calls to this, they will only execute 10 times per second.
    // This should be the single point of entry for fetching things out of the image cache...
    @MainActor func assignTasksToDownloader() async {
        
        if isAssigningTasksToDownloader {
            isAssigningTasksToDownloaderEnqueued = true
            return
        }
        
        if layout.numberOfCells() <= 0 {
            return
        }
        
        let containerTopY = layout.getContainerTop()
        let containerBottomY = layout.getContainerBottom()
        if containerBottomY <= containerTopY {
            return
        }
        
        var firstCellIndexOnScreen = layout.firstCellIndexOnScreen() - Self.probeAheadOrBehindRangeForDownloads
        if firstCellIndexOnScreen < 0 {
            firstCellIndexOnScreen = 0
        }
        
        var lastCellIndexOnScreen = layout.lastCellIndexOnScreen() + Self.probeAheadOrBehindRangeForDownloads
        if lastCellIndexOnScreen >= numberOfCells {
            lastCellIndexOnScreen = numberOfCells - 1
        }
        
        guard lastCellIndexOnScreen > firstCellIndexOnScreen else {
            return
        }
        
        let containerRangeY = containerTopY...containerBottomY
        
        isAssigningTasksToDownloader = true
        
        _addDownloadItems.removeAll(keepingCapacity: true)
        _checkCacheDownloadItems.removeAll(keepingCapacity: true)
        
        var cellIndex = firstCellIndexOnScreen
        while cellIndex < lastCellIndexOnScreen {
            if let communityCellModel = getCommunityCellModel(at: cellIndex) {
                if let key = communityCellModel.key {
                    
                    if _imageDict[key] != nil {
                        // We already have this image, don't do anything at all with it
                        cellIndex += 1
                        continue
                    }
                    
                    if _imageFailedSet.contains(communityCellModel.index) {
                        // This one failed already, don't do anything at all with it
                        cellIndex += 1
                        continue
                    }
                    
                    if _imageDidCheckCacheSet.contains(communityCellModel.index) {
                        // We have already checked the image cache for this,
                        // so we should just download it. No need to hit the
                        // cache an extra time with this request.
                        
                        _addDownloadItems.append(communityCellModel)
                    } else {
                        // We have never checked the image cache, let's first
                        // check the image cache, then if it whiffs, we can
                        // download it in this pass as well...
                        
                        _checkCacheDownloadItems.append(communityCellModel)
                    }
                }
            }
            cellIndex += 1
        }
        
        await _loadUpImageCacheAndHandOffMissesToDownloadList()
        
        await _loadUpDownloaderAndComputePriorities(containerTopY: containerTopY, containerRangeY: containerRangeY)
        
        await downloader.startTasksIfNecessary()
        
        //
        // Let's not bunch up requests calls to this.
        // If they bunch up, we enqueue another call.
        //
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        isAssigningTasksToDownloader = false
        if isAssigningTasksToDownloaderEnqueued {
            Task { @MainActor in
                isAssigningTasksToDownloaderEnqueued = false
                await assignTasksToDownloader()
            }
        }
    }
    
    @MainActor func _loadUpImageCacheAndHandOffMissesToDownloadList() async {
        if _checkCacheDownloadItems.count > 0 {
            
            _checkCacheKeys.removeAll(keepingCapacity: true)
            
            for communityCellModel in _checkCacheDownloadItems {
                _imageDidCheckCacheSet.insert(communityCellModel.index)
                if let key = communityCellModel.key {
                    let keyAndIndexPair = KeyAndIndexPair(key: key, index: communityCellModel.index)
                    _checkCacheKeys.append(keyAndIndexPair)
                }
            }
            
            let cacheDict = await imageCache.batchRetrieve(_checkCacheKeys)
            
            // If it was NOT in the cache, let's download it...
            for communityCellModel in _checkCacheDownloadItems {
                if let key = communityCellModel.key {
                    let keyAndIndexPair = KeyAndIndexPair(key: key, index: communityCellModel.index)
                    if cacheDict[keyAndIndexPair] === nil {
                        print("\(key) was NOT in the cache, we will download it...")
                        _addDownloadItems.append(communityCellModel)
                    }
                }
            }
            
            // If it WAS in the cache, let's store the image and
            // update the UI. This was a successful cache hit!
            for (keyAndIndexPair, image) in cacheDict {
                _imageDict[keyAndIndexPair.key] = image
                //if let communityCellModel = getCommunityCellModel(at: keyAndIndexPair.index) {
                    //movieGridView?.handleImageChanged(index: communityCellModel.index)
                    cellNeedsUpdatePublisher.send(keyAndIndexPair.index)
                //}
                
                // Let the UI update.
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }
    
    @MainActor func _loadUpDownloaderAndComputePriorities(containerTopY: Int, containerRangeY: ClosedRange<Int>) async {
        
        await downloader.addDownloadTaskBatch(_addDownloadItems)
        
        let taskList = await downloader.taskList
        
        _priorityCommunityCellModels.removeAll(keepingCapacity: true)
        _priorityList.removeAll(keepingCapacity: true)
        
        for task in taskList {
            let cellIndex = task.index
            if let communityCellModel = getCommunityCellModel(at: cellIndex) {
                
                let cellLeftX = layout.getCellLeft(withCellIndex: cellIndex)
                let cellTopY = layout.getCellTop(withCellIndex: cellIndex)
                let cellBottomY = layout.getCellBottom(withCellIndex: cellIndex)
                let cellRangeY = cellTopY...cellBottomY
                
                let overlap = containerRangeY.overlaps(cellRangeY)
                
                if overlap {
                    
                    let distX = cellLeftX
                    let distY = max(cellTopY - containerTopY, 0)
                    let priority = priority(distX: distX, distY: distY)
                    
                    _priorityCommunityCellModels.append(communityCellModel)
                    _priorityList.append(priority)
                } else {
                    _priorityCommunityCellModels.append(communityCellModel)
                    _priorityList.append(0)
                }
            }
        }
        await downloader.setPriorityBatch(_priorityCommunityCellModels, _priorityList)
    }
}

extension CommunityViewModel: GridLayoutDelegate {
    @MainActor func cellsDidEnterScreen(_ cellIndices: [Int]) {
        handleCellsMayHaveChanged()
    }
    
    @MainActor func cellsDidLeaveScreen(_ cellIndices: [Int]) {
        handleCellsMayHaveChanged()
    }
    
    @MainActor func layoutDidChangeWidth() {
        layoutFrameWidthUpdatePublisher.send(layout.width)
        if layout.isAnyItemPresent {
            isAnyItemPresent = true
        }
    }
    
    @MainActor func layoutDidChangeHeight() {
        layoutFrameHeightUpdatePublisher.send(layout.height)
        if layout.isAnyItemPresent {
            isAnyItemPresent = true
        }
    }
}

extension CommunityViewModel: DirtyImageDownloaderDelegate {
    @MainActor func dataDownloadDidStart(_ index: Int) {
        _imageDownloadingActivelySet.insert(index)
        cellNeedsUpdatePublisher.send(index)
    }
    
    @MainActor func dataDownloadDidSucceed(_ index: Int, image: UIImage) {
        _imageDownloadingSet.remove(index)
        _imageDownloadingActivelySet.remove(index)
        _imageFailedSet.remove(index)
        if let communityCellModel = getCommunityCellModel(at: index) {
            if let key = communityCellModel.key {
                _imageDict[key] = image
                cellNeedsUpdatePublisher.send(index)
                Task {
                    await self.imageCache.cacheImage(image, key)
                }
            }
        }
    }
    
    @MainActor func dataDownloadDidCancel(_ index: Int) {
        print("🧩 We had an image cancel its download @ \(index)")
        _imageDownloadingSet.remove(index)
        _imageDownloadingActivelySet.remove(index)
        cellNeedsUpdatePublisher.send(index)
    }
    
    @MainActor func dataDownloadDidFail(_ index: Int) {
        print("🎲 We had an image fail to download @ \(index)")
        _imageDownloadingSet.remove(index)
        _imageDownloadingActivelySet.remove(index)
        _imageFailedSet.insert(index)
        cellNeedsUpdatePublisher.send(index)
    }
}
