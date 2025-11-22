import Foundation
import Vapor

struct MurmurConfig: Codable {
    var server: ServerConfig = ServerConfig()
    var whisper: WhisperConfig = WhisperConfig()
    var database: DatabaseConfig = DatabaseConfig()
    
    struct ServerConfig: Codable {
        var host: String = "0.0.0.0"
        var port: Int = 8000
    }
    
    struct WhisperConfig: Codable {
        var model: String = "small"
        var modelsPath: String?
    }
    
    struct DatabaseConfig: Codable {
        var path: String = "./murmur.db"
    }
    
    static func load() -> MurmurConfig {
        var config = MurmurConfig()
        
        // Try to load from config file (YAML or JSON)
        if let fileConfig = loadFromFile() {
            config = fileConfig
        }
        
        // Override with environment variables if present
        if let host = Environment.get("HOST") {
            config.server.host = host
        }
        if let portStr = Environment.get("PORT"), let port = Int(portStr) {
            config.server.port = port
        }
        if let model = Environment.get("WHISPER_MODEL") {
            config.whisper.model = model
        }
        if let modelsPath = Environment.get("WHISPER_MODELS_PATH") {
            config.whisper.modelsPath = modelsPath
        }
        if let dbPath = Environment.get("DATABASE_PATH") {
            config.database.path = dbPath
        }
        
        return config
    }
    
    private static func loadFromFile() -> MurmurConfig? {
        let fileManager = FileManager.default
        
        // Check for explicit config path from environment variable
        if let configPath = Environment.get("MURMUR_CONFIG") {
            guard fileManager.fileExists(atPath: configPath) else {
                print("Warning: MURMUR_CONFIG set to '\(configPath)' but file not found")
                return nil
            }
            
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                return try parseYAML(data: data)
            } catch {
                print("Warning: Failed to load config from \(configPath): \(error)")
                return nil
            }
        }
        
        // Fall back to default paths
        let configPaths = [
            "murmur.yaml",
            "murmur.yml",
            ".murmur.yaml",
            ".murmur.yml"
        ]
        
        for configPath in configPaths {
            guard fileManager.fileExists(atPath: configPath) else { continue }
            
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                return try parseYAML(data: data)
            } catch {
                print("Warning: Failed to load config from \(configPath): \(error)")
            }
        }
        
        return nil
    }
    
    private static func parseYAML(data: Data) throws -> MurmurConfig {
        guard let content = String(data: data, encoding: .utf8) else {
            throw ConfigError.invalidFormat
        }
        
        var config = MurmurConfig()
        let lines = content.split(separator: "\n")
        
        var currentSection: String?
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            
            // Check for section headers
            if trimmed.hasSuffix(":") && !trimmed.contains(" ") {
                currentSection = String(trimmed.dropLast())
                continue
            }
            
            // Parse key-value pairs
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            
            switch currentSection {
            case "server":
                switch key {
                case "host":
                    config.server.host = value
                case "port":
                    if let port = Int(value) {
                        config.server.port = port
                    }
                default:
                    break
                }
            case "whisper":
                switch key {
                case "model":
                    config.whisper.model = value
                case "modelsPath", "models_path":
                    config.whisper.modelsPath = value
                default:
                    break
                }
            case "database":
                switch key {
                case "path":
                    config.database.path = value
                default:
                    break
                }
            default:
                // Top-level keys (backwards compatibility)
                break
            }
        }
        
        return config
    }
    
    enum ConfigError: Error {
        case invalidFormat
    }
}
