import Fluent
import Vapor

final class MurmurJob: Model, Content, @unchecked Sendable {
    static let schema = "murmur_jobs"
    
    @ID(custom: "id", generatedBy: .user)
    var id: String?
    
    @Field(key: "status")
    var status: String
    
    @Field(key: "progress")
    var progress: Double
    
    @Field(key: "transcript")
    var transcript: String
    
    @Field(key: "transcript_segments")
    var transcriptSegments: String
    
    @Field(key: "error_message")
    var errorMessage: String
    
    @Field(key: "created_at")
    var createdAt: Int
    
    @Field(key: "updated_at")
    var updatedAt: Int
    
    init() { }
    
    init(id: String, status: String = "pending", progress: Double = 0, 
         transcript: String = "", transcriptSegments: String = "", 
         errorMessage: String = "", createdAt: Int, updatedAt: Int) {
        self.id = id
        self.status = status
        self.progress = progress
        self.transcript = transcript
        self.transcriptSegments = transcriptSegments
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum JobStatus: String {
    case pending
    case processing
    case transcribing
    case completed
    case failed
}
