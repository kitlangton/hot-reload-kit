import Foundation

package struct ReloadCommand: Codable, Sendable, Equatable {
  package let generation: Int
  package let artifactPath: String
  package let declaration: String

  package init(generation: Int, artifactPath: String, declaration: String) {
    self.generation = generation
    self.artifactPath = artifactPath
    self.declaration = declaration
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
