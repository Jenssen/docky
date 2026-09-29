//
//  FolderAccessService.swift
//  Docky
//
//  Reads folder contents for preview tiles. Relies on the .userFolders
//  permission granted via Full Disk Access. Silent no-op when access isn't
//  granted.
//

import Combine
import Dispatch
import Foundation

enum FolderContentsSnapshot: Equatable {
    case loaded([URL])
    case unreadable
}

final class FolderAccessService: ObservableObject {
    static let shared = FolderAccessService()

    @Published private(set) var changeToken: UInt64 = 0

    private let staleAfter: TimeInterval = 15
    private var contentsCache: [URL: (date: Date, items: [URL])] = [:]
    private var watchersByURL: [URL: FolderWatcher] = [:]
    private var sortCache: [FolderSortCacheKey: (date: Date, items: [URL])] = [:]
    private let maxSortCacheEntries = 32
    private var sortEntries: [URL: (date: Date, entry: FolderSortEntry)] = [:]

    private init() {}

    deinit {
        for watcher in watchersByURL.values {
            watcher.source.cancel()
        }
    }

    /// All visible contents of the folder, newest-modified first.
    /// Cached briefly to avoid hitting the filesystem on every view update.
    func contents(of folderURL: URL) -> [URL] {
        if case .loaded(let items) = snapshot(of: folderURL) {
            return items
        }
        return []
    }

    func snapshot(of folderURL: URL) -> FolderContentsSnapshot {
        cachedSnapshot(of: folderURL)
    }

    func sortedContents(of folderURL: URL, sortMode: FolderTileSortMode) -> [URL] {
        sortedItems(in: contents(of: folderURL), sortMode: sortMode)
    }

    /// Memoized for `staleAfter` seconds, same window as the contents cache.
    /// Views read the sorted list several times per update (layout math plus
    /// the grid itself), and every uncached sort re-reads resource values
    /// from disk for each item.
    func sortedItems(in items: [URL], sortMode: FolderTileSortMode) -> [URL] {
        let key = FolderSortCacheKey(items: items, sortMode: sortMode)
        if let cached = sortCache[key],
           Date().timeIntervalSince(cached.date) < staleAfter {
            return cached.items
        }

        // Prefer the metadata captured while the folder was read. URLs drop
        // their prefetched resource values when the run loop turns, so
        // building entries here would go back to disk for every item.
        let now = Date()
        var metadataDate = now
        let entries = items.map { url -> FolderSortEntry in
            if let captured = sortEntries[url],
               now.timeIntervalSince(captured.date) < staleAfter {
                metadataDate = min(metadataDate, captured.date)
                return captured.entry
            }
            return FolderSortEntry(url: url)
        }

        let sorted = sortedURLs(from: entries, sortMode: sortMode)
        if sortCache.count >= maxSortCacheEntries {
            sortCache.removeAll()
        }
        // Dated by the metadata, not the sort, so captured values never
        // outlive `staleAfter`.
        sortCache[key] = (metadataDate, sorted)
        return sorted
    }

    private func sortedURLs(from entries: [FolderSortEntry], sortMode: FolderTileSortMode) -> [URL] {
        entries.sorted { lhs, rhs in
            switch sortMode {
            case .name:
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate > rhs.modificationDate
                }
            case .dateModified:
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate > rhs.modificationDate
                }
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            case .dateCreated:
                if lhs.creationDate != rhs.creationDate {
                    return lhs.creationDate > rhs.creationDate
                }
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            case .dateAdded:
                if lhs.addedDate != rhs.addedDate {
                    return lhs.addedDate > rhs.addedDate
                }
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            case .kind:
                let kindComparison = lhs.kind.localizedStandardCompare(rhs.kind)
                if kindComparison != .orderedSame {
                    return kindComparison == .orderedAscending
                }
                let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }
            case .size:
                if lhs.size != rhs.size {
                    return lhs.size > rhs.size
                }
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            }

            return lhs.url.path < rhs.url.path
        }
        .map(\.url)
    }

    func sortedItems(in snapshot: FolderContentsSnapshot, sortMode: FolderTileSortMode) -> [URL] {
        guard case .loaded(let items) = snapshot else {
            return []
        }

        return sortedItems(in: items, sortMode: sortMode)
    }

    /// Up to `limit` URLs from the folder, newest-modified first.
    func recentContents(of folderURL: URL, sortMode: FolderTileSortMode, limit: Int = 3) -> [URL] {
        Array(sortedContents(of: folderURL, sortMode: sortMode).prefix(limit))
    }

    func beginWatching(_ folderURL: URL, ownerID: String) {
        let normalizedFolderURL = folderURL.standardizedFileURL
        if var watcher = watchersByURL[normalizedFolderURL] {
            watcher.ownerIDs.insert(ownerID)
            watchersByURL[normalizedFolderURL] = watcher
            return
        }

        let descriptor = open(normalizedFolderURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link, .revoke],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.handleWatcherEvent(for: normalizedFolderURL)
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }

        watchersByURL[normalizedFolderURL] = FolderWatcher(
            ownerIDs: [ownerID],
            source: source
        )
        source.resume()
    }

    func endWatching(_ folderURL: URL, ownerID: String) {
        let normalizedFolderURL = folderURL.standardizedFileURL
        guard var watcher = watchersByURL[normalizedFolderURL] else {
            return
        }

        watcher.ownerIDs.remove(ownerID)
        guard watcher.ownerIDs.isEmpty else {
            watchersByURL[normalizedFolderURL] = watcher
            return
        }

        watchersByURL.removeValue(forKey: normalizedFolderURL)
        watcher.source.cancel()
    }

    private func cachedSnapshot(of folderURL: URL) -> FolderContentsSnapshot {
        let normalizedFolderURL = folderURL.standardizedFileURL

        if let cached = contentsCache[normalizedFolderURL],
           Date().timeIntervalSince(cached.date) < staleAfter {
            return .loaded(cached.items)
        }

        guard FileManager.default.isReadableFile(atPath: normalizedFolderURL.path) else {
            return .unreadable
        }

        let keys: [URLResourceKey] = [
            .addedToDirectoryDateKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .localizedNameKey,
            .localizedTypeDescriptionKey,
            .totalFileAllocatedSizeKey
        ]
        guard let listed = try? FileManager.default.contentsOfDirectory(
            at: normalizedFolderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return .unreadable
        }

        // The listing prefetched `keys`, so capturing the sort metadata now
        // costs no extra disk access.
        let now = Date()
        removeSortEntries(forContentsOf: normalizedFolderURL)
        let entries = listed.map(FolderSortEntry.init)
        for entry in entries {
            sortEntries[entry.url] = (now, entry)
        }
        let loaded = entries
            .sorted(by: { $0.modificationDate > $1.modificationDate })
            .map(\.url)

        contentsCache[normalizedFolderURL] = (now, loaded)
        return .loaded(loaded)
    }

    func invalidateCache() {
        contentsCache.removeAll()
        sortCache.removeAll()
        sortEntries.removeAll()
    }

    private func invalidateCache(for folderURL: URL) {
        removeSortEntries(forContentsOf: folderURL.standardizedFileURL)
        contentsCache.removeValue(forKey: folderURL.standardizedFileURL)
        sortCache.removeAll()
    }

    private func removeSortEntries(forContentsOf normalizedFolderURL: URL) {
        guard let cached = contentsCache[normalizedFolderURL] else {
            return
        }

        for url in cached.items {
            sortEntries.removeValue(forKey: url)
        }
    }

    private func handleWatcherEvent(for folderURL: URL) {
        invalidateCache(for: folderURL)
        changeToken &+= 1
    }
}

private struct FolderWatcher {
    var ownerIDs: Set<String>
    let source: DispatchSourceFileSystemObject
}

private struct FolderSortCacheKey: Hashable {
    let items: [URL]
    let sortMode: FolderTileSortMode
}

private struct FolderSortEntry {
    let url: URL
    let displayName: String
    let modificationDate: Date
    let creationDate: Date
    let addedDate: Date
    let kind: String
    let size: Int
    let isDirectory: Bool

    nonisolated init(url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .addedToDirectoryDateKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .localizedNameKey,
            .localizedTypeDescriptionKey,
            .totalFileAllocatedSizeKey
        ])
        self.url = url
        self.displayName = values?.localizedName ?? url.lastPathComponent
        self.modificationDate = values?.contentModificationDate ?? .distantPast
        self.creationDate = values?.creationDate ?? .distantPast
        self.addedDate = values?.addedToDirectoryDate ?? .distantPast
        self.kind = values?.localizedTypeDescription ?? ""
        self.size = values?.fileSize ?? values?.totalFileAllocatedSize ?? 0
        self.isDirectory = values?.isDirectory == true
    }
}
