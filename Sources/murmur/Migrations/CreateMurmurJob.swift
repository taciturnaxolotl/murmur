import Fluent

struct CreateMurmurJob: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("murmur_jobs")
            .field("id", .string, .identifier(auto: false))
            .field("status", .string, .required)
            .field("progress", .double, .required)
            .field("transcript", .string, .required)
            .field("error_message", .string, .required)
            .field("created_at", .int, .required)
            .field("updated_at", .int, .required)
            .create()
    }
    
    func revert(on database: Database) async throws {
        try await database.schema("murmur_jobs").delete()
    }
}
