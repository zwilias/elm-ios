import UIKit
import YogaKit
import JavaScriptCore

class ViewController: UIViewController {
    
    static var nextTimerId = 0
    static var timerRegistry = [Int: DispatchSourceTimer]()
    let jsQueue: DispatchQueue = DispatchQueue(label: "jsQueue")
    var jsContext: JSContext!
    var window: UIWindow?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.window = UIWindow(frame: UIScreen.main.bounds)
        
        let containerSize: CGSize = self.view.bounds.size
        
        let root = self.view!
        root.backgroundColor = .white
        root.configureLayout { (layout) in
            layout.isEnabled = true
            layout.width = YGValue(containerSize.width)
            layout.height = YGValue(containerSize.height)
        }
        
        jsQueue.async {
            // Setup all the requisite JS stuff
            self.initJsContext()
            
            // launch Elm program once everything is loaded
            _ = self.jsContext
                .objectForKeyedSubscript("Elm")
                .objectForKeyedSubscript("Main")
                .objectForKeyedSubscript("start")
                .call(withArguments: [])
        }
    }
    
    private static func timer(on queue: DispatchQueue) -> (Int, DispatchSourceTimer) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let timerId = nextTimerId
        
        timerRegistry[nextTimerId] = timer
        nextTimerId += 1
        
        return (timerId, timer)
    }
    
    private func initJsContext() {
        let context: JSContext = JSContext()
        
        // expose initialRender and applyPatches to JS global context
        let initialRender: @convention(block) ([String : Any], [[String : Any]]) -> Void = { (view, handlerList) in
            let handlerList = handlerList
            DispatchQueue.main.async {
                Renderer.initialRender(view: view, handlers: handlerList)
            }
        }
        context.setObject(initialRender, forKeyedSubscript: "initialRender" as (NSCopying & NSObjectProtocol)!)
        
        let applyPatches: @convention(block) ([String : Any]) -> Void = { (patches) in
            var patches = patches
            
            DispatchQueue.main.async {
                Renderer.applyPatches(&patches)
            }
        }
        context.setObject(applyPatches, forKeyedSubscript: "applyPatches" as (NSCopying & NSObjectProtocol)!)
        
        // expose Swift implementations of setTimeout, setInterval, and clearInterval to JS global context
        let setTimeout: @convention(block) (JSValue, Double) -> Int = { (function, timeout) in
            let (id, timer) = ViewController.timer(on: self.jsQueue)
            
            timer.setEventHandler {
                function.call(withArguments: [])
                ViewController.timerRegistry.removeValue(forKey: id)
            }
            
            timer.scheduleOneshot(deadline: DispatchTime.now() + timeout)
            timer.resume()
            
            return id
        }
        context.setObject(setTimeout, forKeyedSubscript: "setTimeout" as (NSCopying & NSObjectProtocol)!)
        
        let setInterval: @convention(block) (JSValue, Double) -> Int = { (function, interval) in
            let (id, timer) = ViewController.timer(on: self.jsQueue)
            
            timer.setEventHandler {
                function.call(withArguments: [])
            }
            
            timer.scheduleRepeating(deadline: DispatchTime.now(), interval: interval / 1000.0)
            timer.resume()
            
            return id
        }
        context.setObject(setInterval, forKeyedSubscript: "setInterval" as (NSCopying & NSObjectProtocol)!)
        
        let clearTimer: @convention(block) (Int) -> Void = { id in
            if let timer = ViewController.timerRegistry[id] {
                timer.cancel()
                ViewController.timerRegistry.removeValue(forKey: id)
            }
        }
        
        context.setObject(clearTimer, forKeyedSubscript: "clearInterval" as (NSCopying & NSObjectProtocol)!)
        context.setObject(clearTimer, forKeyedSubscript: "clearTimeout" as (NSCopying & NSObjectProtocol)!)
        
        // expose Swift implementations of console.* to JS global context
        let consoleLog: @convention(block) (String) -> Void = { message in
            print("JS Console: " + message)
        }
        
        context.setObject([:], forKeyedSubscript: "console" as (NSCopying & NSObjectProtocol)!)
        context.objectForKeyedSubscript("console").setObject(consoleLog, forKeyedSubscript: "log" as (NSCopying & NSObjectProtocol)!)
        
        // log JS exceptions
        context.exceptionHandler = { context, exception in
            print("JS Error: \(exception?.description ?? "unknown error")")
        }
        
        // load compiled Elm program
        guard let appJsPath = Bundle.main.path(forResource: "compiledElm", ofType: "js") else {
            return
        }
        
        do {
            let app = try String(contentsOfFile: appJsPath, encoding: String.Encoding.utf8)
            _ = context.evaluateScript(app)
        } catch (let error) {
            print("Error while processing script file: \(error)")
        }
        
        self.jsContext = context
    }
    
    // recompute the layout when the device is rotated
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        self.view.configureLayout { (layout) in
            layout.width = YGValue(size.width)
            layout.height = YGValue(size.height)
        }
        redrawRootView()
    }
    
    // helper for adding the "pseudo root view" to the root view
    func addToRootView(subview: UIView) {
        self.view.addSubview(subview)
    }
    
    // helper for recomputing the entire layout
    func redrawRootView() {
        self.view.yoga.applyLayout(preservingOrigin: true)
    }
    
    // Swift interface for the handleEvent JS function that manages callbacks
    func handleEvent(id: UInt64, name: String, data: Any) {
        jsQueue.async {
            _ = self.jsContext
                .objectForKeyedSubscript("Elm")
                .objectForKeyedSubscript("Main")
                .objectForKeyedSubscript("handleEvent")
                .call(withArguments: [id, name, data])
        }
    }
    
}

