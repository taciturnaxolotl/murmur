import Vapor
import Fluent
import FluentSQLiteDriver

@main
struct Murmur {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        
        let app = try await Application.make(env)
        defer { 
            Task {
                try? await app.asyncShutdown()
            }
        }
        
        var isShuttingDown = false
        
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signalSource.setEventHandler {
            guard !isShuttingDown else {
                print("\nForce quitting...")
                exit(1)
            }
            isShuttingDown = true
            
            print("\n")
            print("Shutting down gracefully... (Press Ctrl+C again to force quit)")
            
            Task {
                do {
                    try await app.asyncShutdown()
                    exit(0)
                } catch {
                    print("Error during shutdown: \(error)")
                    exit(1)
                }
            }
        }
        signal(SIGINT, SIG_IGN)
        signalSource.resume()
        
        let signalSource2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        signalSource2.setEventHandler {
            guard !isShuttingDown else { return }
            isShuttingDown = true
            
            print("\nReceived SIGTERM, shutting down...")
            
            Task {
                do {
                    try await app.asyncShutdown()
                    exit(0)
                } catch {
                    print("Error during shutdown: \(error)")
                    exit(1)
                }
            }
        }
        signal(SIGTERM, SIG_IGN)
        signalSource2.resume()
        
        do {
            try await configure(app)
            try await app.execute()
        } catch {
            print("Server error: \(error)")
            throw error
        }
    }
}

func configure(_ app: Application) async throws {
    let config = MurmurConfig.load()
    
    app.databases.use(.sqlite(.file(config.database.path)), as: .sqlite)
    
    app.migrations.add(CreateMurmurJob())
    try await app.autoMigrate()
    
    app.logger.info("Initializing WhisperKit...")
    let transcriptionService = TranscriptionService(config: config.whisper)
    try await transcriptionService.initialize()
    app.logger.info("WhisperKit initialized successfully")
    
    app.http.server.configuration.hostname = config.server.host
    app.http.server.configuration.port = config.server.port
    
    app.routes.defaultMaxBodySize = "500mb"
    
    try routes(app, transcriptionService: transcriptionService)
    
    app.logger.info("Murmur server starting on \(config.server.host):\(config.server.port)")
}

func routes(_ app: Application, transcriptionService: TranscriptionService) throws {
    app.get { req async in
        "Murmur - WhisperKit Transcription Server"
    }
    
    let controller = TranscriptionController(transcriptionService: transcriptionService)
    try app.register(collection: controller)
}
