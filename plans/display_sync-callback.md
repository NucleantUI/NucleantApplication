# Unified DisplaySync class / NucleantSync target

example on macOS / iOS we use DisplayLink 
and normally you define what fps you want by just whole number
unless you ask for max.

just have some unified DisplaySync class 

```swift

public final class DisplaySync {

    public static let shared: DisplaySync = .init()
    private var handlers: [Int:SyncCallbackHandler] = [:] // only to keep them alive
    private var primaryHandler: PrimarySyncHandler? // only to keep it alive
    init() {

    }

    public static func newCallback(fps: Int, callback: (Double)->Void) -> Int { 
        /* if no key exist
        create new and add callback
        return int index of where it should be removed later on..

        */
    }

    public static func destroyCallback(fps: Int, index: Int) {
        .....
    }
}


// depends on platform
// should already be covered for most platforms
// just need same kind of logic here
final class SyncCallbackHandler:  {

    var fps: Int

    var callbacks: [(Double)->Void] // all targets same fps callback

    // internal logic handles how each platform deals with callback from
    // there way of doing display synced callbacks 
}

// ignore for now, first do the first 2 classes..
// before replacing current display sync with this.. 
final class PrimarySyncHandler:  {

    var fps: Int

    var callbacks: [(Double)->Void] // all targets same fps callback

    // as the other class but this should just focus on only what NucleantUI
    // needs, and the other class is for when you need more custom callbacks
    // for same display sync as this primary will feed NucleantUI with..

}

```

atm it would be usefull for things like games that need to tap into the displaysync
since our nucleantui doesnt really passes it down the line..
and for games it would just require a single callback..


