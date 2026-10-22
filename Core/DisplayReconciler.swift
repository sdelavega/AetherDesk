// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import CoreGraphics
import Foundation

struct DisplaySnapshot: Equatable {
    let info: DisplayHardwareInfo
    let identity: DisplayIdentity
}

enum RestoreSource: Equatable {
    case session(UUID), persisted, fallback
}

enum DisplayAction: Equatable {
    case tearDownHost(CGDirectDisplayID)
    case createHost(CGDirectDisplayID, frame: CGRect)
    case restore(CGDirectDisplayID, RestoreSource)
    case reframeHost(CGDirectDisplayID, frame: CGRect)
}

enum DisplayReconciler {
    static func reconcile(previous: [DisplaySnapshot],
                          current: [DisplaySnapshot],
                          sessionBundles: [DisplayIdentity: UUID]) -> [DisplayAction] {
        let previous = previous.sorted { $0.info.displayID < $1.info.displayID }
        let current = current.sorted { $0.info.displayID < $1.info.displayID }
        var actions: [DisplayAction] = []

        for old in previous {
            let kept = current.contains {
                $0.info.displayID == old.info.displayID && $0.identity == old.identity
            }
            if !kept {
                actions.append(.tearDownHost(old.info.displayID))
            }
        }

        for display in current {
            let kept = previous.contains {
                $0.info.displayID == display.info.displayID && $0.identity == display.identity
            }
            if !kept {
                let id = display.info.displayID
                actions.append(.createHost(id, frame: display.info.frame))
                let source = sessionBundles[display.identity].map { RestoreSource.session($0) } ?? .persisted
                actions.append(.restore(id, source))
            }
        }

        for display in current {
            if let old = previous.first(where: {
                $0.info.displayID == display.info.displayID && $0.identity == display.identity
            }), old.info.frame != display.info.frame {
                actions.append(.reframeHost(display.info.displayID, frame: display.info.frame))
            }
        }
        return actions
    }
}
