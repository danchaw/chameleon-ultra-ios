import Foundation
import SwiftUI

/// Saved card, JSON-compatible with the original app's `CardSave`
/// (uid hex string, atqa/ats as byte arrays, data = list of 16/4-byte blocks).
struct CardSave: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var uid: String
    var sak: Int = 0
    var atqa: [UInt8] = []
    var ats: [UInt8] = []
    var name: String
    var tag: Int
    var color: String = "#E64A19"
    var data: [[UInt8]] = []
    var folderId: String? = nil

    var tagType: TagType {
        get { TagType(rawValue: UInt16(tag)) ?? .unknown }
        set { tag = Int(newValue.rawValue) }
    }

    var isMifareClassic: Bool { tagType.isMifareClassic }
    var isEV1: Bool {
        guard tagType == .mifare1K, data.count > 64 else { return false }
        for block in data[64..<min(72, data.count)] where !block.isEmpty { return true }
        return false
    }

    var displayType: String {
        tagType.displayName + (isEV1 ? " EV1" : "")
    }

    var uidData: Data { Data(hex: uid) }

    /// All 6-byte keys found in sector trailers (A and B).
    var dumpKeys: [Data] {
        var keys: [Data] = []
        for sector in 0..<40 {
            let block = MifareClassic.sectorTrailerBlock(sector: sector)
            guard data.count > block, data[block].count == 16 else { continue }
            keys.append(Data(data[block][0..<6]))
            keys.append(Data(data[block][10..<16]))
        }
        return keys
    }

    /// Flatten blocks into one binary dump (export .bin compatible with the original).
    var binaryDump: Data {
        Data(data.flatMap { $0 })
    }

    enum CodingKeys: String, CodingKey {
        case id, uid, sak, atqa, ats, name, tag, color, data
        case extra, folderId
    }

    init(uid: String, name: String, tag: TagType, sak: Int = 0, atqa: [UInt8] = [], ats: [UInt8] = [],
         data: [[UInt8]] = []) {
        self.uid = uid
        self.name = name
        self.tag = Int(tag.rawValue)
        self.sak = sak
        self.atqa = atqa
        self.ats = ats
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        uid = try c.decode(String.self, forKey: .uid)
        sak = (try? c.decode(Int.self, forKey: .sak)) ?? 0
        atqa = (try? c.decode([UInt8].self, forKey: .atqa)) ?? []
        ats = (try? c.decode([UInt8].self, forKey: .ats)) ?? []
        name = (try? c.decode(String.self, forKey: .name)) ?? "Card"
        tag = (try? c.decode(Int.self, forKey: .tag)) ?? 0
        color = (try? c.decode(String.self, forKey: .color)) ?? "#E64A19"
        data = (try? c.decode([[UInt8]].self, forKey: .data)) ?? []
        folderId = try? c.decode(String.self, forKey: .folderId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString, forKey: .id)
        try c.encode(uid, forKey: .uid)
        try c.encode(sak, forKey: .sak)
        try c.encode(atqa, forKey: .atqa)
        try c.encode(ats, forKey: .ats)
        try c.encode(name, forKey: .name)
        try c.encode(tag, forKey: .tag)
        try c.encode(color, forKey: .color)
        try c.encode(data, forKey: .data)
        try c.encode([String: String](), forKey: .extra)
        if let folderId { try c.encode(folderId, forKey: .folderId) }
    }

    static func fromBinaryDump(_ dump: Data, uid: String, sak: Int, atqa: [UInt8],
                               name: String, tag: TagType) -> CardSave {
        let blockSize = tag.isMifareClassic ? 16 : 4
        var blocks: [[UInt8]] = []
        var offset = 0
        while offset + blockSize <= dump.count {
            blocks.append(Array(dump[offset..<offset + blockSize]))
            offset += blockSize
        }
        return CardSave(uid: uid, name: name, tag: tag, sak: sak, atqa: atqa, data: blocks)
    }
}

/// Key dictionary, JSON-compatible with the original app.
struct KeyDictionary: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var color: String = "#E64A19"
    var keys: [[UInt8]] = []
    var keyLength: Int = 12
    var folderId: String? = nil

    var keyData: [Data] { keys.map { Data($0) } }

    init(name: String, keys: [Data] = []) {
        self.name = name
        self.keys = keys.map { Array($0) }
        self.keyLength = keys.first?.count ?? 0
    }

    /// Parse a text list of hex keys (one per line), same rules as the original.
    static func fromText(_ text: String, name: String) -> KeyDictionary {
        let allowedKeySizes = [12, 8, 32]
        var keys: [Data] = []
        var currentKeySize = 0
        for rawLine in text.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: " ")
            if line.contains(" ") { line = String(line.split(separator: " ")[0]) }
            if allowedKeySizes.contains(line.count),
               line.data(using: .utf8)?.isValidHex ?? false,
               currentKeySize == 0 || currentKeySize == line.count {
                if currentKeySize == 0 { currentKeySize = line.count }
                keys.append(Data(hex: line))
            }
        }
        var dict = KeyDictionary(name: name, keys: keys)
        dict.keyLength = currentKeySize
        return dict
    }
}

/// Persistence for cards + dictionaries, JSON files inside the app container,
/// import/export compatible with the original app.
@MainActor
final class CardStore: ObservableObject {
    @Published var cards: [CardSave] = []
    @Published var dictionaries: [KeyDictionary] = []

    private static var cardsFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cards.json")
    }
    private static var dictionariesFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dictionaries.json")
    }

    init() {
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: Self.cardsFile),
           let list = try? JSONDecoder().decode([CardSave].self, from: data) {
            cards = list
        }
        if let data = try? Data(contentsOf: Self.dictionariesFile),
           let list = try? JSONDecoder().decode([KeyDictionary].self, from: data) {
            dictionaries = list
        }
    }

    func persist() {
        if let data = try? JSONEncoder().encode(cards) {
            try? data.write(to: Self.cardsFile, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(dictionaries) {
            try? data.write(to: Self.dictionariesFile, options: .atomic)
        }
    }

    func add(_ card: CardSave) {
        cards.append(card)
        persist()
    }

    func update(_ card: CardSave) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
            persist()
        }
    }

    func delete(_ card: CardSave) {
        cards.removeAll { $0.id == card.id }
        persist()
    }

    func add(dictionary: KeyDictionary) {
        dictionaries.append(dictionary)
        persist()
    }

    func delete(dictionary: KeyDictionary) {
        dictionaries.removeAll { $0.id == dictionary.id }
        persist()
    }

    func importCards(from data: Data) -> Int {
        var imported = 0
        if let list = try? JSONDecoder().decode([CardSave].self, from: data) {
            for card in list where !cards.contains(where: { $0.id == card.id }) {
                cards.append(card)
                imported += 1
            }
        } else if let single = try? JSONDecoder().decode(CardSave.self, from: data),
                  !cards.contains(where: { $0.id == single.id }) {
            cards.append(single)
            imported = 1
        }
        if imported > 0 { persist() }
        return imported
    }
}
