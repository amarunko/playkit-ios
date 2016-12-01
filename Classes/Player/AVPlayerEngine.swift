//
//  AVPlayerEngine.swift
//  Pods
//
//  Created by Eliza Sapir on 07/11/2016.
//
//

import Foundation
import AVFoundation
import AVKit
import CoreMedia

class AVPlayerEngine : AVPlayer {
    
    private var avPlayerLayer: AVPlayerLayer!
    
    private var _view: PlayerView!
    private var currentState: PlayerState = PlayerState.idle
    
//  AVPlayerItem.currentTime() and the AVPlayerItem.timebase's rate are not KVO observable. We check their values regularly using this timer.
    private let nonObservablePropertiesUpdateTimer = DispatchSource.makeTimerSource(flags: [], queue: DispatchQueue.main)
    
    public var onEventBlock: ((PKEvent)->Void)?
    
    public var view: UIView! {
        get {
            PKLog.trace("get player view: \(_view)")
            return _view
        }
    }
    
    public var currentPosition: Double {
        get {
            PKLog.trace("get currentPosition: \(self.currentTime())")
            return CMTimeGetSeconds(self.currentTime())
        }
        set {
            PKLog.trace("set currentPosition: \(currentPosition)")
            let newTime = CMTimeMakeWithSeconds(newValue, 1)
            super.seek(to: newTime, toleranceBefore: kCMTimeZero, toleranceAfter: kCMTimeZero)
            
            self.postEvent(event: PlayerEvents.seeking())
        }
    }
    
    public var duration: Double {
        guard let currentItem = self.currentItem else { return 0.0 }
        PKLog.trace("get duration: \(self.currentItem?.duration)")
        return CMTimeGetSeconds(self.currentItem!.duration)
    }
    
    public override init() {
        PKLog.trace("init AVPlayer")
        super.init()
        
        avPlayerLayer = AVPlayerLayer(player: self)
        _view = PlayerView(playerLayer: avPlayerLayer)
        self.onEventBlock = nil
    }
    
    deinit {
        self.destroy()
    }
    
    private func setupNonObservablePropertiesUpdateTimer() {
        PKLog.trace("setupNonObservablePropertiesUpdateTimer")
        
        nonObservablePropertiesUpdateTimer.setEventHandler { [weak self] in
            self?.updateNonObservableProperties()
        }
        nonObservablePropertiesUpdateTimer.scheduleRepeating(deadline: DispatchTime.now(), interval: DispatchTimeInterval.milliseconds(50))
    }
    
    /**
     Convenience method for setting shouldPlayWhenReady to true.
     */
    public func load() {
        PKLog.trace("load player")
    }
    
    public override func pause() {

        if self.rate == 1.0 {
            // Playing, so pause.
            PKLog.trace("pause player")
            super.pause()
        }
    }
    
    public override func play() {

        if self.rate != 1.0 {
            PKLog.trace("play player")
            
            self.postEvent(event: PlayerEvents.play())
            super.play()
        }
    }
    
    func prepareNext(_ config: PlayerConfig) -> Bool {
        if let sources = config.mediaEntry?.sources {
            if sources.count > 0 {
                if let contentUrl = sources[0].contentUrl {
                    PKLog.trace("prepareNext item for player")
                    self.replaceCurrentItem(with: AVPlayerItem(url: contentUrl))
                    self.setupNonObservablePropertiesUpdateTimer()
                    self.addObservers()
                }
            }
        }
        return true
    }
    
    func loadNext() -> Bool {
        PKLog.trace("loadNext item for player")
        return false
    }
    
    func destroy() {
        PKLog.trace("destory player")
        self.removeObservers()
    }
    
    @available(iOS 9.0, *)
    func createPiPController(with delegate: AVPictureInPictureControllerDelegate) -> AVPictureInPictureController?{
        let pip = AVPictureInPictureController(playerLayer: avPlayerLayer)
        pip?.delegate = delegate
        return pip
    }
    
    // MARK: - KVO Observation
    
    // An array of key paths for the properties we want to observe.
    private let observedKeyPaths = [
        #keyPath(rate),
        #keyPath(currentItem.status),
        #keyPath(currentItem),
        #keyPath(currentItem.playbackLikelyToKeepUp),
        #keyPath(currentItem.playbackBufferEmpty),
        #keyPath(currentItem.duration)
        //        #keyPath(currentItem.tracks)
    ]
    
    private var observerContext = 0
    
    // - Observers
    func addObservers() {
        PKLog.trace("addObservers")
        
        // Register observers for the properties we want to display.
        for keyPath in observedKeyPaths {
            addObserver(self, forKeyPath: keyPath, options: [.new, .initial], context: &observerContext)
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.playerFailed(notification:)), name: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime, object: self.currentItem)
        NotificationCenter.default.addObserver(self, selector: #selector(self.playerPlayedToEnd(notification:)), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: self.currentItem)
    }
    
    func removeObservers() {
        do {
            try
                PKLog.trace("removeObservers")
            // Un-register observers
            for keyPath in observedKeyPaths {
                removeObserver(self, forKeyPath: keyPath, context: &observerContext)
            }
            
            NotificationCenter.default.removeObserver(self)
            
            
        } catch  {
            PKLog.trace("can't removeObservers")
        }
    }
    
    public func playerFailed(notification: NSNotification) {
        let newState = PlayerState.error
        self.postStateChange(newState: newState, oldState: self.currentState)
        self.currentState = newState
        
        self.postEvent(event: PlayerEvents.error())
    }
    
    public func playerPlayedToEnd(notification: NSNotification) {
        let newState = PlayerState.idle
        self.postStateChange(newState: newState, oldState: self.currentState)
        self.currentState = newState
        
        self.postEvent(event: PlayerEvents.ended())
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        PKLog.debug("observeValue:: onEvent/onState")
        
        guard context == &observerContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        var event: PKEvent? = nil
        
        if keyPath == #keyPath(currentItem.isPlaybackLikelyToKeepUp) {
            if let item = self.currentItem {
                let newState = PlayerState.ready
                self.postStateChange(newState: newState, oldState: self.currentState)
                self.currentState = newState
            }
        } else if keyPath == #keyPath(currentItem.isPlaybackBufferEmpty) {
            if let item = self.currentItem {
                let newState = PlayerState.idle
                self.postStateChange(newState: newState, oldState: self.currentState)
                self.currentState = newState
            }
        } else if keyPath == #keyPath(currentItem.duration) {
            event = PlayerEvents.durationChange(duration: CMTimeGetSeconds((self.currentItem?.duration)!))
        } else if keyPath == #keyPath(rate) {
            if rate == 1.0 {
                nonObservablePropertiesUpdateTimer.resume()
            } else {
                event = PlayerEvents.pause()
            }
        } else if keyPath == #keyPath(currentItem.status) {
            if currentItem?.status == .readyToPlay {
                let newState = PlayerState.ready
                self.postStateChange(newState: newState, oldState: self.currentState)
                self.currentState = newState
                
                event = PlayerEvents.canPlay()
            } else if currentItem?.status == .failed {
                let newState = PlayerState.error
                self.postStateChange(newState: newState, oldState: self.currentState)
                self.currentState = newState
                
                event = PlayerEvents.error()
            }
        } else if keyPath == #keyPath(currentItem) {
            let newState = PlayerState.idle
            self.postStateChange(newState: newState, oldState: self.currentState)
            self.currentState = newState
        }

        if let currentEvent: PKEvent = event {
           self.postEvent(event: currentEvent)
        }
    }
    
    private func postEvent(event: PKEvent) {
        PKLog.trace("onEvent:: \(event)")
        
        if let block = onEventBlock {
            block(event)
        }
    }
    
    private func postStateChange(newState: PlayerState, oldState: PlayerState) {
        PKLog.trace("stateChanged:: new:\(newState) old:\(oldState)")
        let stateChangedEvent: PKEvent = PlayerEvents.stateChanged(newState: newState, oldState: oldState)
        
        self.postEvent(event: stateChangedEvent)
    }
    
    private func updateNonObservableProperties() {
        if let currItem = self.currentItem {
            if let timebase = currItem.timebase {
                if let timebaseRate: Float64 = CMTimebaseGetRate(timebase){
                    if timebaseRate == 1.0 {
                        self.postEvent(event: PlayerEvents.playing())
                        nonObservablePropertiesUpdateTimer.suspend()
                    }
                    
                    PKLog.trace("timebaseRate:: \(timebaseRate)")
                }
            }
        }
    }
}
