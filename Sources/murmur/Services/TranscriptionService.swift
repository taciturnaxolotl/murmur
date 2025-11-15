import Vapor
import WhisperKit
import Foundation
import Fluent
import AVFoundation

actor TranscriptionService {
    private var whisperKit: WhisperKit?
    private let tempDirectory: URL
    private var activeJobs: Set<String> = []
    private let logger = Logger(label: "murmur.transcription")
    
    init() {
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    func initialize() async throws {
        guard whisperKit == nil else { return }
        
        let modelName = Environment.get("WHISPER_MODEL") ?? "small"
        
        let config = WhisperKitConfig(model: modelName)
        
        whisperKit = try await WhisperKit(config)
    }
    
    func startTranscription(jobId: String, audioData: Data, fileExtension: String, db: any Database) async {
        guard !activeJobs.contains(jobId) else { return }
        activeJobs.insert(jobId)
        
        let tempFilePath = tempDirectory.appendingPathComponent("\(jobId).\(fileExtension)")
        
        logger.info("Starting transcription for job \(jobId) (format: .\(fileExtension))")
        
        do {
            try audioData.write(to: tempFilePath)
            
            logger.info("Audio file size: \(audioData.count) bytes")
            
            // Get audio duration for progress calculation
            var audioDurationSeconds = 0.0
            let asset = AVAsset(url: tempFilePath)
            let duration = try await asset.load(.duration)
            audioDurationSeconds = duration.seconds
            
            // Calculate estimated segments (approx 1 segment per 5 seconds)
            let estimatedSegments = max(1, Int(audioDurationSeconds / 5.0))
            
            logger.info("Audio duration: \(String(format: "%.1f", audioDurationSeconds)) seconds, estimated \(estimatedSegments) segments")
            
            try await updateJob(jobId, status: "processing", progress: 0, db: db)
            
            guard let whisper = whisperKit else {
                throw Abort(.internalServerError, reason: "WhisperKit not initialized")
            }
            
            logger.info("Transcribing audio file for job \(jobId)...")
            
            try await updateJob(jobId, status: "transcribing", progress: 0, db: db)
            
            var lastProgress: Double = 0
            var lastLogTime = Date()
            var callbackCount = 0
            var logCount = 0
            
            let results = try await whisper.transcribe(
                audioPath: tempFilePath.path,
                callback: { progress in
                    callbackCount += 1
                    
                    // Only log every 2 seconds to avoid spam
                    let now = Date()
                    if now.timeIntervalSince(lastLogTime) >= 2.0 {
                        lastLogTime = now
                        logCount += 1
                        
                        // Increment progress with each log
                        let currentProgress = Double(logCount) * 100.0 / Double(estimatedSegments)
                        
                        if currentProgress > lastProgress {
                            lastProgress = currentProgress
                            
                            let transcript = progress.text.isEmpty ? "" : progress.text
                            
                            print("[\(jobId)] Progress: \(String(format: "%.1f", currentProgress))% (callbacks: \(callbackCount)/~\(estimatedSegments)) - \(transcript.prefix(50))...")
                            
                            Task {
                                try? await self.updateJob(
                                    jobId,
                                    status: "transcribing",
                                    progress: currentProgress,
                                    transcript: transcript,
                                    db: db
                                )
                            }
                        }
                    }
                    return true
                }
            )
            
            let fullTranscript = results.map { $0.text }.joined(separator: " ")
            
            // Build segments with timestamps
            var segmentsData: [[String: Any]] = []
            for result in results {
                for segment in result.segments {
                    segmentsData.append([
                        "id": segment.id,
                        "start": segment.start,
                        "end": segment.end,
                        "text": segment.text
                    ])
                }
            }
            
            let segmentsJson = (try? JSONSerialization.data(withJSONObject: segmentsData))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            
            logger.info("Transcription completed for job \(jobId) - \(fullTranscript.count) characters, \(segmentsData.count) segments, total callbacks: \(callbackCount)")
            
            try await updateJob(
                jobId,
                status: "completed",
                progress: 100.0,
                transcript: fullTranscript,
                transcriptSegments: segmentsJson,
                db: db
            )
            
        } catch {
            logger.error("Transcription failed for job \(jobId): \(error.localizedDescription)")
            try? await updateJob(
                jobId,
                status: "failed",
                errorMessage: error.localizedDescription,
                db: db
            )
        }
        
        try? FileManager.default.removeItem(at: tempFilePath)
        activeJobs.remove(jobId)
    }
    
    private func updateJob(
        _ jobId: String,
        status: String? = nil,
        progress: Double? = nil,
        transcript: String? = nil,
        transcriptSegments: String? = nil,
        errorMessage: String? = nil,
        db: any Database
    ) async throws {
        guard let job = try await MurmurJob.find(jobId, on: db) else {
            return
        }
        
        if let status = status {
            job.status = status
        }
        if let progress = progress {
            job.progress = progress
        }
        if let transcript = transcript {
            job.transcript = transcript
        }
        if let transcriptSegments = transcriptSegments {
            job.transcriptSegments = transcriptSegments
        }
        if let errorMessage = errorMessage {
            job.errorMessage = errorMessage
        }
        
        job.updatedAt = Int(Date().timeIntervalSince1970)
        try await job.save(on: db)
    }
}
