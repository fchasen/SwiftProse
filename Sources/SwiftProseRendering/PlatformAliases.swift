import Foundation

#if canImport(AppKit) && os(macOS)
import AppKit
public typealias PlatformView = NSView
public typealias PlatformTextView = NSTextView
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformFontDescriptor = NSFontDescriptor
#elseif canImport(UIKit)
import UIKit
public typealias PlatformView = UIView
public typealias PlatformTextView = UITextView
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformFontDescriptor = UIFontDescriptor
#endif
