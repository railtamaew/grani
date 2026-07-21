import Foundation

extension String {
  func splitToArray(
    separator: Character = ",",
    trimmingCharacters: CharacterSet? = nil
  ) -> [String] {
    split(separator: separator).map {
      if let trimmingCharacters {
        return $0.trimmingCharacters(in: trimmingCharacters)
      }
      return String($0)
    }
  }
}
