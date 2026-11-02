import Foundation

/// Turns a failed service's log into a one-line fix for causes outside DevPilot's control,
/// such as an expired cloud sign-in or a missing language version.
public enum LocalRunDiagnosis {
    /// - Parameter environment: the service's variables, plus its `.env` file, used to name
    ///   the AWS profile in the suggested command.
    public static func hint(forLog log: String, environment: [String: String] = [:]) -> String? {
        let awsProfile = environment["AWS_PROFILE"].map { " --profile \($0)" } ?? ""
        if log.contains("InvalidSSOToken") || log.contains("Token has expired and refresh failed")
            || log.contains("SSO session associated with this profile has expired")
            || log.contains("SSOTokenProviderFailure") {
            return "The AWS SSO sign-in has expired. Run `aws sso login\(awsProfile)`, then start again."
        }
        if let match = log.firstMatch(of: /rbenv: version `([^']+)' is not installed/) {
            return rubyHint(String(match.1))
        }
        if let match = log.firstMatch(of: /Your Ruby version is \S+, but your Gemfile specified (\S+)/) {
            return rubyHint(String(match.1))
        }
        if let match = log.firstMatch(of: /N\/A: version "([^"]+)" is not yet installed/) {
            return "Node \(match.1) isn't installed. Run `nvm install \(match.1)`, then start again."
        }
        if log.contains("EADDRINUSE") || log.contains("Address already in use") {
            return "A port the service needs is taken. Check that the command uses its {{port.NAME}} placeholder rather than a fixed port."
        }
        return nil
    }

    private static func rubyHint(_ version: String) -> String {
        "Ruby \(version) isn't installed. Run `rbenv install \(version)` (if rbenv doesn't know that version, `brew upgrade ruby-build` first), then start again."
    }

    /// Reads `KEY=value` lines from a dotenv file; quotes around values are removed.
    static func dotenv(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).replacing("export ", with: "")
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}
