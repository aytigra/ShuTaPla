//
//  AudioStripper.swift
//  ShuTaPla
//
//  Removes the audio track from a video by remuxing it with libavformat: the video
//  stream's packets are copied verbatim into a fresh container and the audio (and any
//  other non-video stream) is left behind. No decode or re-encode, so it is fast and
//  lossless, and it works for every container the player can open — including the
//  webm/mkv files AVFoundation can't write.
//
//  It uses the FFmpeg libraries libmpv already links and the bundle step already embeds,
//  so it needs no external `ffmpeg` binary. The muxer is inferred from the output file's
//  extension.
//

import Foundation
import Cffmpeg

// `nonisolated`: this project defaults to `@MainActor` isolation, but the remux blocks on
// a background Dispatch queue, and its `pool.run` closure must not be MainActor-isolated.
nonisolated enum AudioStripper {

    /// One background-priority lane for remuxes. Stream-copy is I/O-bound, so serializing
    /// keeps it off the player's decode cores at little cost.
    private static let pool = DispatchQueue(label: "com.aytigra.ShuTaPla.audio-strip", qos: .utility)

    /// Remuxes the video at `input` into `output`, copying the video stream and dropping
    /// every other (audio, data, subtitle) stream. Returns the failure (the step and
    /// libavformat's error), `nil` when `output` was written. Runs the blocking remux off the
    /// cooperative thread pool so a large file never ties up a concurrency-limited Swift task
    /// thread.
    static func stripAudio(at input: URL, to output: URL) async -> String? {
        await pool.run { () -> String? in
            do throws(Failure) {
                try remux(input: input.path, output: output.path)
                return nil
            } catch {
                log(error.message)
                // A mid-stream failure (write header/frame/trailer) can leave a truncated,
                // unplayable file at the destination. Remove it so callers never see a
                // corrupt output — `remux`'s `defer`s have already closed the file handles.
                try? FileManager.default.removeItem(at: output)
                return error.message
            }
        }
    }

    private struct Failure: Error {
        let message: String
    }

    /// The libavformat copy loop. Synchronous and blocking — only called from
    /// `stripAudio(at:to:)`.
    private static func remux(input: String, output: String) throws(Failure) {
        var inCtx: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_open_input(&inCtx, input, nil, nil), "Open input")
        guard let inCtx else { throw Failure(message: "Open input failed") }
        defer { var c: UnsafeMutablePointer<AVFormatContext>? = inCtx; avformat_close_input(&c) }

        try check(avformat_find_stream_info(inCtx, nil), "Read stream info")

        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&outCtx, nil, nil, output), "Allocate output")
        guard let outCtx else { throw Failure(message: "Allocate output failed") }
        defer {
            if outCtx.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 { avio_closep(&outCtx.pointee.pb) }
            avformat_free_context(outCtx)
        }

        // Map each input stream to an output stream, keeping only video. A `-1` entry marks
        // a dropped stream (audio and everything else) whose packets are skipped below.
        let inputStreamCount = Int(inCtx.pointee.nb_streams)
        var outputIndex = [Int32](repeating: -1, count: inputStreamCount)
        var next: Int32 = 0
        for i in 0..<inputStreamCount {
            guard let inStream = inCtx.pointee.streams[i],
                  inStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            guard let outStream = avformat_new_stream(outCtx, nil) else {
                throw Failure(message: "Allocate output stream failed")
            }
            try check(avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar),
                      "Copy codec parameters")
            outStream.pointee.codecpar.pointee.codec_tag = 0   // let the muxer pick the tag
            outputIndex[i] = next
            next += 1
        }
        guard next > 0 else { throw Failure(message: "No video stream to keep") }

        if outCtx.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 {
            try check(avio_open(&outCtx.pointee.pb, output, AVIO_FLAG_WRITE), "Open output file")
        }
        try check(avformat_write_header(outCtx, nil), "Write header")

        guard let packet = av_packet_alloc() else { throw Failure(message: "Allocate packet failed") }
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }

        while av_read_frame(inCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let source = Int(packet.pointee.stream_index)
            guard source < inputStreamCount else { continue }
            let target = outputIndex[source]
            guard target >= 0,
                  let inStream = inCtx.pointee.streams[source],
                  let outStream = outCtx.pointee.streams[Int(target)] else { continue }

            packet.pointee.stream_index = target
            av_packet_rescale_ts(packet, inStream.pointee.time_base, outStream.pointee.time_base)
            packet.pointee.pos = -1
            // `av_interleaved_write_frame` takes the packet's contents (it unrefs internally),
            // so the deferred `av_packet_unref` is a safe no-op afterwards.
            try check(av_interleaved_write_frame(outCtx, packet), "Write frame")
        }

        try check(av_write_trailer(outCtx), "Write trailer")
    }

    /// Throws the failure of step `what` for an FFmpeg return code (negative is an error).
    private static func check(_ code: Int32, _ what: String) throws(Failure) {
        guard code < 0 else { return }
        throw Failure(message: "\(what) failed: \(errorString(code))")
    }

    private static func errorString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func log(_ message: String) {
        NSLog("[AudioStripper] %@", message)
    }
}
