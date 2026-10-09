import Foundation

package struct ReloadCommand: Codable, Sendable, Equatable {
  package let generation: Int
  package let artifactPath: String
  package let declaration: String
  package let declarations: [String]

  package init(
    generation: Int,
    artifactPath: String,
    declaration: String,
    declarations: [String]? = nil
  ) {
    self.generation = generation
    self.artifactPath = artifactPath
    self.declaration = declaration
    self.declarations = declarations ?? [declaration]
  }

  private enum CodingKeys: String, CodingKey {
    case generation
    case artifactPath
    case declaration
    case declarations
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    generation = try container.decode(Int.self, forKey: .generation)
    artifactPath = try container.decode(String.self, forKey: .artifactPath)
    declaration = try container.decode(String.self, forKey: .declaration)
    declarations =
      try container.decodeIfPresent([String].self, forKey: .declarations) ?? [declaration]
  }
}

package struct ReloadReceipt: Codable, Sendable, Equatable {
  package let generation: Int
  package let error: String?

  package init(generation: Int, error: String? = nil) {
    self.generation = generation
    self.error = error
  }
}
