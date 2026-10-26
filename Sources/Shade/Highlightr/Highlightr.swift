// Adapted from Highlightr (https://github.com/raspu/Highlightr), MIT License. See THIRD_PARTY_NOTICES.md.
//
//  Highlightr.swift
//  Pods
//
//  Created by Illanes, J.P. on 4/10/16.
//
//

import Foundation
import JavaScriptCore

#if os(OSX)
    import AppKit
#endif

/// Utility class for generating a highlighted NSAttributedString from a String.
open class Highlightr
{
    /// Returns the current Theme.
    open var theme : HighlightTheme!
    {
        didSet
        {
            themeChanged?(theme)
        }
    }
    
    /// This block will be called every time the theme changes.
    open var themeChanged : ((HighlightTheme) -> Void)?

    /// Defaults to `false` - when `true`, forces highlighting to finish even if illegal syntax is detected.
    open var ignoreIllegals = false

    private let hljs: JSValue

    /// Shade: folders with `<name>.min.css` / `<name>.css` themes; later folders win.
    private let themeDirectories: [URL]
    private let htmlStart = "<"
    private let spanStart = "span class=\""
    private let spanStartClose = "\">"
    private let spanEnd = "/span>"
    private let htmlEscape = try! NSRegularExpression(pattern: "&#?[a-zA-Z0-9]+?;", options: .caseInsensitive)
    
    /**
     Shade: loads highlight.js from `highlightPath`, themes from `themeDirectories` and extra language
     definitions (browser builds that call `hljs.registerLanguage`) from `languageFiles`. Upstream reads
     everything from its SwiftPM resource bundle instead.
     */
    public init?(highlightPath: String, themeDirectories: [URL], languageFiles: [URL] = [])
    {
        guard let jsContext = JSContext() else { return nil }
        self.themeDirectories = themeDirectories

        guard let hgJs = try? String(contentsOfFile: highlightPath, encoding: .utf8) else { return nil }
        jsContext.evaluateScript(hgJs)
        guard let hljs = jsContext.objectForKeyedSubscript("hljs"), !hljs.isUndefined else { return nil }
        self.hljs = hljs

        for file in languageFiles
        {
            if let script = try? String(contentsOf: file, encoding: .utf8)
            {
                jsContext.evaluateScript(script)
            }
        }

        guard setTheme(to: "atom-one-dark") || availableThemes().first.map({ setTheme(to: $0) }) == true else
        {
            return nil
        }
    }
    
    /**
     Set the theme to use for highlighting.
     
     - parameter to: Theme name
     
     - returns: true if it was possible to set the given theme, false otherwise
     */
    @discardableResult
    open func setTheme(to name: String) -> Bool
    {
        let candidates = themeDirectories.reversed().flatMap { directory in
            [directory.appendingPathComponent(name + ".min.css"), directory.appendingPathComponent(name + ".css")]
        }
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let themeString = try? String(contentsOf: file, encoding: .utf8) else { return false }
        theme =  HighlightTheme(themeString: themeString)

        
        return true
    }
    
    /**
     Takes a String and returns a NSAttributedString with the given language highlighted.
     
     - parameter code:           Code to highlight.
     - parameter languageName:   Language name or alias. Set to `nil` to use auto detection.
     - parameter fastRender:     Defaults to true - When *true* will use the custom made html parser rather than Apple's solution.
     
     - returns: NSAttributedString with the detected code highlighted.
     */
    open func highlight(_ code: String, as languageName: String? = nil, fastRender: Bool = true) -> NSAttributedString?
    {
        let ret: JSValue?
        if let languageName = languageName
        {
            let result: JSValue = hljs.invokeMethod("highlight", withArguments: [languageName, code, ignoreIllegals])
			 if result.isUndefined {
				// If highlighting failed, use highlightAuto
				ret = hljs.invokeMethod("highlightAuto", withArguments: [code])
			} else {
				ret = result
			}
        }else
        {
            // language auto detection
            ret = hljs.invokeMethod("highlightAuto", withArguments: [code])
        }

        guard let res = ret?.objectForKeyedSubscript("value"), var string = res.toString() else
        {
            return nil
        }
        
        var returnString : NSAttributedString?
        if(fastRender)
        {
            returnString = processHTMLString(string)
        }else
        {
            string = "<style>"+theme.lightTheme+"</style><pre><code class=\"hljs\">"+string+"</code></pre>"
            let opt: [NSAttributedString.DocumentReadingOptionKey : Any] = [
             .documentType: NSAttributedString.DocumentType.html,
             .characterEncoding: String.Encoding.utf8.rawValue
             ]
            
            guard let data = string.data(using: String.Encoding.utf8) else { return nil }
            safeMainSync
            {
                returnString = try? NSMutableAttributedString(data:data, options: opt, documentAttributes:nil)
            }
        }
        
        return returnString
    }
    
    /**
     Returns a list of all the available themes.
     
     - returns: Array of Strings
     */
    open func availableThemes() -> [String]
    {
        var result = Set<String>()
        for directory in themeDirectories
        {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files where file.hasSuffix(".css")
            {
                result.insert(file.replacingOccurrences(of: ".min.css", with: "").replacingOccurrences(of: ".css", with: ""))
            }
        }
        return result.sorted()
    }
    
    /**
     Returns a list of all supported languages.
     
     - returns: Array of Strings
     */
    open func supportedLanguages() -> [String]
    {
        let res = hljs.invokeMethod("listLanguages", withArguments: [])
        return (res?.toArray() as? [String]) ?? []
    }
    
    /**
     Execute the provided block in the main thread synchronously.
     */
    private func safeMainSync(_ block: @escaping ()->())
    {
        if Thread.isMainThread
        {
            block()
        }else
        {
            DispatchQueue.main.sync { block() }
        }
    }
    
    private func processHTMLString(_ string: String) -> NSAttributedString?
    {
        let scanner = Scanner(string: string)
        scanner.charactersToBeSkipped = nil
        var scannedString: NSString?
        let resultString = NSMutableAttributedString(string: "")
        var propStack = ["hljs"]
        
        while !scanner.isAtEnd
        {
            var ended = false
            if scanner.scanUpTo(htmlStart, into: &scannedString)
            {
                if scanner.isAtEnd
                {
                    ended = true
                }
            }
            
            if scannedString != nil && scannedString!.length > 0 {
                let attrScannedString = theme.applyStyleToString(scannedString! as String, styleList: propStack)
                resultString.append(attrScannedString)
                if ended
                {
                    continue
                }
            }
            
            scanner.scanLocation += 1
            
            let string = scanner.string as NSString
            let nextChar = string.substring(with: NSMakeRange(scanner.scanLocation, 1))
            if(nextChar == "s")
            {
                scanner.scanLocation += (spanStart as NSString).length
                scanner.scanUpTo(spanStartClose, into:&scannedString)
                scanner.scanLocation += (spanStartClose as NSString).length
                propStack.append(scannedString! as String)
            }
            else if(nextChar == "/")
            {
                scanner.scanLocation += (spanEnd as NSString).length
                propStack.removeLast()
            }else
            {
                let attrScannedString = theme.applyStyleToString("<", styleList: propStack)
                resultString.append(attrScannedString)
                scanner.scanLocation += 1
            }
            
            scannedString = nil
        }
        
        let results = htmlEscape.matches(in: resultString.string,
                                               options: [.reportCompletion],
                                               range: NSMakeRange(0, resultString.length))
        var locOffset = 0
        for result in results
        {
            let fixedRange = NSMakeRange(result.range.location-locOffset, result.range.length)
            let entity = (resultString.string as NSString).substring(with: fixedRange)
            if let decodedEntity = HTMLUtils.decode(entity)
            {
                resultString.replaceCharacters(in: fixedRange, with: String(decodedEntity))
                locOffset += result.range.length-1;
            }
            

        }

        return resultString
    }
    
}
