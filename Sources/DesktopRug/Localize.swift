import Foundation

/// 介面文字跟著系統語言：中文系統顯示中文，其他一律英文
let prefersChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func L(_ zh: String, _ en: String) -> String { prefersChinese ? zh : en }
