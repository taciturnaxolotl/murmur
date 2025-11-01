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
        let filename = content.file.filename
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
            transcriptSegments: "[]",
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
        
        
        let format = req.query[String.self, at: "format"] ?? "json"

        let response: [String: Any] = [
            "status": job.status,
            "progress": job.progress,
            "transcript": job.transcript,
            "error_message": job.errorMessage
        ]

        if format == "json" {
            // Default JSON response
            var jsonResponse = response
            
            if let segmentsData = job.transcriptSegments.data(using: .utf8) {
                let segments = try? JSONSerialization.jsonObject(with: segmentsData, options: [])
                jsonResponse["transcript_segments"] = segments
            } else {
                jsonResponse["transcript_segments"] = []
            }

            return try Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: JSONSerialization.data(withJSONObject: jsonResponse))
            )
        } else if format == "vtt" {
            // VTT response
            var vtt = "WEBVTT\n\n"
            if let segmentsData = job.transcriptSegments.data(using: .utf8),
               let segments = try? JSONDecoder().decode([[String: AnyDecodable]].self, from: segmentsData) {
                for segment in segments {
                    let start = segment["start"]?.value as? Double ?? 0.0
                    let end = segment["end"]?.value as? Double ?? 0.0
                    let text = segment["text"]?.value as? String ?? ""
                    
                    let startFormatted = formatTimestamp(start)
                    let endFormatted = formatTimestamp(end)
                    
                    vtt += "\(startFormatted) --> \(endFormatted)\n"
                    vtt += "\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
                }
            }
            return Response(status: .ok, headers: ["Content-Type": "text/vtt"], body: .init(string: vtt))
        } else {
            throw Abort(.badRequest, reason: "Unsupported format. Use 'json' or 'vtt'.")
        }
    }
    
    private func formatTimestamp(_ timestamp: Double) -> String {
        let hours = Int(timestamp) / 3600
        let minutes = (Int(timestamp) % 3600) / 60
        let seconds = Int(timestamp) % 60
        let milliseconds = Int((timestamp - Double(Int(timestamp))) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    struct AnyDecodable: Decodable {
        let value: Any

        init<T>(_ value: T?) {
            self.value = value ?? ()
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            if let intVal = try? container.decode(Int.self) {
                value = intVal
            } else if let doubleVal = try? container.decode(Double.self) {
                value = doubleVal
            } else if let stringVal = try? container.decode(String.self) {
                value = stringVal
            } else if let boolVal = try? container.decode(Bool.self) {
                value = boolVal
            } else {
                throw DecodingError.typeMismatch(AnyDecodable.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported type"))
            }
        }
    }
    
    func streamJob(req: Request) async throws -> Response {
        guard let jobId = req.parameters.get("jobId") else {
            throw Abort(.badRequest, reason: "Missing job ID")
        }
        
        // Get Last-Event-ID header for reconnection support
        let lastEventId = req.headers.first(name: "Last-Event-ID").flatMap { Int($0) } ?? 0
        
        return Response(
            status: .ok,
            headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no"
            ],
            body: .init(stream: { writer in
                Task {
                    var lastUpdated = lastEventId
                    var didClose = false
                    var jobNotFoundCount = 0
                    var heartbeatCounter = 0
                    
                    let logger = Logger(label: "murmur.stream")
                    logger.info("Stream started for job \(jobId), lastEventId: \(lastEventId)")
                    
                    do {
                        while true {
                            let job: MurmurJob?
                            do {
                                job = try await MurmurJob.find(jobId, on: req.db)
                            } catch {
                                logger.warning("DB error looking up job \(jobId): \(error)")
                                job = nil
                            }
                            
                            guard let job = job else {
                                // Allow retries - job might be starting up or DB temporarily busy
                                jobNotFoundCount += 1
                                logger.debug("Job \(jobId) not found, attempt \(jobNotFoundCount)/10")
                                if jobNotFoundCount > 10 {
                                    // Only error after 5 seconds of retries (10 * 500ms)
                                    logger.warning("Job \(jobId) not found after 10 attempts, sending error")
                                    let errorEvent = "event: error\ndata: {\"error\":\"Job not found\"}\n\n"
                                    try writer.write(.buffer(.init(string: errorEvent))).wait()
                                    break
                                }
                                try await Task.sleep(nanoseconds: 500_000_000)
                                continue
                            }
                            
                            // Reset counter if job found
                            jobNotFoundCount = 0
                            
                            // Send update if job changed
                            if job.updatedAt > lastUpdated {
                                lastUpdated = job.updatedAt
                                
                                var eventData: [String: Any] = [
                                    "status": job.status,
                                    "progress": job.progress,
                                    "transcript": job.transcript,
                                    "error_message": job.errorMessage
                                ]

                                if job.status == "completed" {
                                    if let segmentsData = job.transcriptSegments.data(using: .utf8),
                                       let segments = try? JSONSerialization.jsonObject(with: segmentsData, options: []) {
                                        eventData["transcript_segments"] = segments
                                    }
                                }
                                
                                if let jsonData = try? JSONSerialization.data(withJSONObject: eventData),
                                   let jsonString = String(data: jsonData, encoding: .utf8) {
                                    // Include event ID for reconnection
                                    let message = "id: \(job.updatedAt)\nevent: update\ndata: \(jsonString)\n\n"
                                    do {
                                        try await writer.write(.buffer(.init(string: message)))
                                    } catch {
                                        // Stream closed by client, exit cleanly
                                        didClose = true
                                        break
                                    }
                                }
                                
                                if job.status == "completed" || job.status == "failed" {
                                    // Give a moment for client to receive the last message
                                    try await Task.sleep(nanoseconds: 100_000_000)
                                    break
                                }
                            } else {
                                // Send heartbeat every 5 iterations (~2.5 seconds) to keep connection alive
                                heartbeatCounter += 1
                                if heartbeatCounter >= 5 {
                                    heartbeatCounter = 0
                                    do {
                                        try await writer.write(.buffer(.init(string: ": heartbeat\n\n")))
                                    } catch {
                                        didClose = true
                                        break
                                    }
                                }
                            }
                            
                            try await Task.sleep(nanoseconds: 500_000_000)
                        }
                    } catch {
                        // Ignore errors, just close
                    }
                    
                    // Always send .end unless client already closed
                    if !didClose {
                        _ = try? writer.write(.end).wait()
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
        return try Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: JSONSerialization.data(withJSONObject: response))
        )
    }
}
