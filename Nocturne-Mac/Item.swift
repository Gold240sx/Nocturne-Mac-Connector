//
//  Item.swift
//  Nocturne-Mac
//
//  Created by Michael Martell on 5/11/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
