import Vapor
import Fluent

struct TranscriptionController: RouteCollection {
    let transcriptionService: TranscriptionService
    
    func boot(routes: RoutesBuilder) throws {
        let transcribe = routes.grouped("transcribe")
        
        transcribe.post(use: createJob)
        transcribe.get(":jobId", use: getJob)
        transcribe.get(":jobId", "stream", use: streamJob)
        transcribe.delete(":jobId", use: deleteJob)
        
        routes.get("jobs", use: listJobs)
    }
    
    func createJob(req: Request) async throws -> Response {
        let jobId = UUID().uuidString
        let now = Int(Date().timeIntervalSince1970)
        
        let content = try req.content.decode(FileUpload.self)
        let fileData = Data(buffer: content.file.data)
        
        var fileExtension = "m4a"
        let filename = content.file.filename ?? ""
        if !filename.isEmpty {
            fileExtension = (filename as NSString).pathExtension.lowercased()
            if fileExtension.isEmpty {
                fileExtension = "m4a"
            }
        }
        
        let job = MurmurJob(
            id: jobId,
            status: "pending",
            progress: 0,
            transcript: "",
            errorMessage: "",
            createdAt: now,
            updatedAt: now
        )
        
        try await job.save(on: req.db)
        
        Task {
            await transcriptionService.startTranscription(
                jobId: jobId,
                audioData: fileData,
                fileExtension: fileExtension,
                db: req.db
            )
        }
        
        let response = ["job_id": jobId]
        return try await response.encodeResponse(for: req)
    }
    
    struct FileUpload: Content {
        var file: File
    }
    
    func getJob(req: Request) async throws -> Response {
        guard let jobId = req.parameters.get("jobId") else {
            throw Abort(.badRequest, reason: "Missing job ID")
        }
        
        guard let job = try await MurmurJob.find(jobId, on: req.db) else {
            throw Abort(.notFound, reason: "Job not found")
        }
        
        let response: [String: Any] = [
            "status": job.status,
            "progress": job.progress,
            "transcript": job.transcript,
            "error_message": job.errorMessage
        ]
        
        return try await Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: JSONSerialization.data(withJSONObject: response))
        )
    }
    
    func streamJob(req: Request) async throws -> Response {
        guard let jobId = req.parameters.get("jobId") else {
            throw Abort(.badRequest, reason: "Missing job ID")
        }
        
        guard let _ = try await MurmurJob.find(jobId, on: req.db) else {
            throw Abort(.notFound, reason: "Job not found")
        }
        
        return Response(
            status: .ok,
            headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive"
            ],
            body: .init(stream: { writer in
                Task {
                    var lastUpdated = 0
                    var didClose = false
                    
                    do {
                        while true {
                            guard let job = try? await MurmurJob.find(jobId, on: req.db) else {
                                break
                            }
                            
                            if job.updatedAt > lastUpdated {
                                lastUpdated = job.updatedAt
                                
                                let eventData: [String: Any] = [
                                    "status": job.status,
                                    "progress": job.progress,
                                    "transcript": job.transcript,
                                    "error_message": job.errorMessage
                                ]
                                
                                if let jsonData = try? JSONSerialization.data(withJSONObject: eventData),
                                   let jsonString = String(data: jsonData, encoding: .utf8) {
                                    do {
                                        try await writer.write(.buffer(.init(string: "data: \(jsonString)\n\n")))
                                    } catch {
                                        // Stream closed by client, exit cleanly
                                        didClose = true
                                        break
                                    }
                                }
                                
                                if job.status == "completed" || job.status == "failed" {
                                    // Give a moment for client to receive the last message
                                    try? await Task.sleep(nanoseconds: 100_000_000)
                                    break
                                }
                            }
                            
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                    } catch {
                        // Ignore errors, just close
                    }
                    
                    // Always send .end unless client already closed
                    if !didClose {
                        try? await writer.write(.end)
                    }
                }
            })
        )
    }
    
    func deleteJob(req: Request) async throws -> Response {
        guard let jobId = req.parameters.get("jobId") else {
            throw Abort(.badRequest, reason: "Missing job ID")
        }
        
        guard let job = try await MurmurJob.find(jobId, on: req.db) else {
            throw Abort(.notFound, reason: "Job not found")
        }
        
        try await job.delete(on: req.db)
        
        let response = ["success": true]
        return try await response.encodeResponse(for: req)
    }
    
    func listJobs(req: Request) async throws -> Response {
        let jobs = try await MurmurJob.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()
        
        let jobsData = jobs.map { job -> [String: Any] in
            [
                "id": job.id ?? "",
                "status": job.status,
                "progress": job.progress,
                "created_at": job.createdAt,
                "updated_at": job.updatedAt
            ]
        }
        
        let response = ["jobs": jobsData]
        return try await Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: JSONSerialization.data(withJSONObject: response))
        )
    }
}
