import Foundation

enum OutputMode: Equatable {
    case signal
    case freeze
    case blank(BlankOption)
    case off

    enum BlankOption: Equatable {
        case black
        case white
        case testPattern
    }
}
