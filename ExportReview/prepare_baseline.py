#!/usr/bin/env python3
"""Inject ONLY a fixture entry point and post-composite hashes into pass1.
This separate executable is the regression reference, not the rewritten pipeline
with optimizations merely disabled. Production rendering/encoding code is untouched.
"""
from pathlib import Path
import shutil
import sys
root, baseline = Path(sys.argv[1]), Path(sys.argv[2])
shutil.copyfile(root/'Screendrop/StudioExportReview.swift', baseline/'Screendrop/StudioExportReview.swift')
p = baseline/'Screendrop/ScreendropApp.swift'
s = p.read_text()
current = (root/'Screendrop/ScreendropApp.swift').read_text()
start = current.index('        #if DEBUG\n        if ProcessInfo.processInfo.environment["SCREENDROP_EXPORT_REVIEW"]')
end = current.index('        #endif', start) + len('        #endif\n')
s = s.replace('    func applicationDidFinishLaunching(_ notification: Notification) {\n',
              '    func applicationDidFinishLaunching(_ notification: Notification) {\n' + current[start:end], 1)
p.write_text(s)
p = baseline/'Screendrop/RecordingStudioExporter.swift'
s = p.read_text().replace('        let frameCount = max(1, Int((duration * frameRate).rounded()))',
                         '        let frameCount = max(1, Int((duration * frameRate).rounded()))\n        #if DEBUG\n        let frameProbe = try StudioExportFrameProbe.make()\n        #endif', 1)
s = s.replace('            if !adaptor.append(destinationBuffer, withPresentationTime: pts) {',
              '            #if DEBUG\n            try frameProbe?.record(destinationBuffer, index: frame, time: pts)\n            #endif\n            if !adaptor.append(destinationBuffer, withPresentationTime: pts) {', 1)
p.write_text(s)
