import SwiftUI

/// Chat views shared by the Mac and iOS apps.
public struct ThreadListView: View {
    public init() {}

    public var body: some View {
        List(["Home"], id: \.self) { Text($0) }
    }
}
