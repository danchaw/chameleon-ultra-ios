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

    /// Parse a text list of hex keys (one per line). Accepts proxmark3
    /// `.dic` (`KEY # comment`) and Flipper `.nfc` (`KEY:comment`) formats.
    /// Written without any index arithmetic — comment-only lines are common
    /// in proxmark3 dictionaries and must not trap.
    static func fromText(_ text: String, name: String) -> KeyDictionary {
        let allowedKeySizes: Set<Int> = [12, 8, 32]
        var keys: [Data] = []
        var seen = Set<String>()
        var currentKeySize = 0
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#") {        // proxmark3 comment
                line = String(line[..<hash])
            }
            if let colon = line.firstIndex(of: ":") {       // flipper comment
                line = String(line[..<colon])
            }
            line = line.trimmingCharacters(in: .whitespaces)

            guard allowedKeySizes.contains(line.count),
                  line.allSatisfy(\.isHexDigit),
                  currentKeySize == 0 || currentKeySize == line.count,
                  seen.insert(line).inserted else { continue }

            if currentKeySize == 0 { currentKeySize = line.count }
            keys.append(Data(hex: line))
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

    /// Tolerant import: accepts a JSON array / single object (our own export
    /// and the original app's format) or a raw binary dump (.bin, tag type
    /// inferred from size like the original `getTagTypeByDumpSize`).
    func importCards(from data: Data) -> Int {
        var imported = 0

        // JSON shape (ours + original app)
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            let rawCards: [[String: Any]]
            if let list = obj as? [[String: Any]] {
                rawCards = list
            } else if let single = obj as? [String: Any], single["uid"] != nil {
                rawCards = [single]
            } else {
                rawCards = []
            }
            for raw in rawCards {
                guard let card = Self.card(fromRaw: raw) else { continue }
                if !cards.contains(where: { $0.id == card.id }) {
                    cards.append(card)
                    imported += 1
                }
            }
            if imported > 0 { persist() }
            return imported
        }

        // binary dump
        if !data.isEmpty, let card = Self.card(fromBinaryDump: data) {
            cards.append(card)
            persist()
            return 1
        }
        return 0
    }

    private static func card(fromRaw raw: [String: Any]) -> CardSave? {
        guard let rawUID = raw["uid"] as? String else { return nil }
        // normalize: original exports may carry "AA BB CC" / "AA:BB:CC" spacing
        let uid = rawUID.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard !uid.isEmpty else { return nil }
        let name = raw["name"] as? String ?? "Card"
        let tagRaw = raw["tag"] as? Int ?? Int(TagType.unknown.rawValue)
        var card = CardSave(uid: uid, name: name, tag: TagType(rawValue: UInt16(tagRaw)) ?? .unknown)
        if let sak = raw["sak"] as? Int { card.sak = sak }
        if let atqa = raw["atqa"] as? [Int] { card.atqa = atqa.map { UInt8($0 & 0xFF) } }
        if let ats = raw["ats"] as? [Int] { card.ats = ats.map { UInt8($0 & 0xFF) } }
        if let color = raw["color"] as? String { card.color = color }
        if let blocks = raw["data"] as? [[Int]] {
            card.data = blocks.map { $0.map { UInt8($0 & 0xFF) } }
        }
        if let folder = raw["folderId"] as? String { card.folderId = folder }
        return card
    }

    /// Port of getTagTypeByDumpSize + block-0 UID extraction.
    private static func card(fromBinaryDump dump: Data) -> CardSave? {
        guard let type = Self.type(byDumpSize: dump.count) else { return nil }
        let blockSize = type.isMifareClassic ? 16 : 4
        var blocks: [[UInt8]] = []
        var offset = 0
        while offset + blockSize <= dump.count {
            blocks.append(Array(dump[offset..<offset + blockSize]))
            offset += blockSize
        }
        var uid = ""
        var sak = 0
        var atqa: [UInt8] = []
        if let first = blocks.first {
            if first[0] == 0x88, first.count >= 8 {          // 7-byte UID cascade
                uid = Data(first[1..<8]).hex
                sak = blocks.count > 1 ? Int(blocks[1][0]) : 0
                atqa = first.count >= 10 ? [first[9], first[8]] : []
            } else if first.count >= 5 {                     // 4-byte UID + BCC
                uid = Data(first[0..<4]).hex
                sak = Int(first[5])
                atqa = first.count >= 8 ? [first[7], first[6]] : []
            }
        }
        return CardSave(uid: uid, name: L10n.t("Imported dump"), tag: type, sak: sak, atqa: atqa, data: blocks)
    }

    private static func type(byDumpSize size: Int) -> TagType? {
        switch size {
        case 320: return .mifareMini
        case 1024, 1088, 1152: return .mifare1K
        case 2048: return .mifare2K
        case 4096: return .mifare4K
        case 64: return .ultralight
        case 192: return .ultralightC
        case 80: return .ultralight11
        case 164: return .ultralight21
        case 180: return .ntag213
        case 540: return .ntag215
        case 924: return .ntag216
        default: return nil
        }
    }
}
