import Combine
import Foundation

/// A buffer responsible for managing the demand of a downstream
/// subscriber for an upstream publisher
///
/// It buffers values and completion events and forwards them dynamically
/// according to the demand requested by the downstream
///
/// In a sense, the subscription only relays the requests for demand, as well
/// the events emitted by the upstream — to this buffer, which manages
/// the entire behavior and backpressure contract
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
class BorrowedDemandBuffer<S: Subscriber> {
    private let lock = NSRecursiveLock()
    private var buffer = [S.Input]()
    private let subscriber: S
    private var completion: Subscribers.Completion<S.Failure>?
    private var demandState = Demand()

    /// Initialize a new demand buffer for a provided downstream subscriber
    ///
    /// - parameter subscriber: The downstream subscriber demanding events
    init(subscriber: S) {
        self.subscriber = subscriber
    }

    /// Buffer an upstream value to later be forwarded to
    /// the downstream subscriber, once it demands it
    ///
    /// - parameter value: Upstream value to buffer
    ///
    /// - returns: The demand fulfilled by the bufferr
    func buffer(value: S.Input) -> Subscribers.Demand {
        precondition(self.completion == nil,
                     "How could a completed publisher sent values?! Beats me 🤷‍♂️")

        switch demandState.requested {
        case .unlimited:
            return subscriber.receive(value)
        default:
            buffer.append(value)
            return flush()
        }
    }

    /// Complete the demand buffer with an upstream completion event
    ///
    /// This method will deplete the buffer immediately,
    /// based on the currently accumulated demand, and relay the
    /// completion event down as soon as demand is fulfilled
    ///
    /// - parameter completion: Completion event
    func complete(completion: Subscribers.Completion<S.Failure>) {
        precondition(self.completion == nil,
                     "Completion have already occured, which is quite awkward 🥺")

        self.completion = completion
        _ = flush()
    }

    /// Signal to the buffer that the downstream requested new demand
    ///
    /// - note: The buffer will attempt to flush as many events rqeuested
    ///         by the downstream at this point
    func demand(_ demand: Subscribers.Demand) -> Subscribers.Demand {
        flush(adding: demand)
    }

    /// Flush buffered events to the downstream based on the current
    /// state of the downstream's demand
    ///
    /// - parameter newDemand: The new demand to add. If `nil`, the flush isn't the
    ///                        result of an explicit demand change
    ///
    /// - note: After fulfilling the downstream's request, if completion
    ///         has already occured, the buffer will be cleared and the
    ///         completion event will be sent to the downstream subscriber
    private func flush(adding newDemand: Subscribers.Demand? = nil) -> Subscribers.Demand {
        lock.lock()
        defer { lock.unlock() }

        if let newDemand = newDemand {
            demandState.requested += newDemand
        }

        // If buffer isn't ready for flushing, return immediately
        guard demandState.requested > 0 || newDemand == Subscribers.Demand.none else { return .none }

        while !buffer.isEmpty && demandState.processed < demandState.requested {
            demandState.requested += subscriber.receive(buffer.remove(at: 0))
            demandState.processed += 1
        }

        if let completion = completion {
            // Completion event was already sent
            buffer = []
            demandState = .init()
            self.completion = nil
            subscriber.receive(completion: completion)
            return .none
        }

        let sentDemand = demandState.requested - demandState.sent
        demandState.sent += sentDemand
        return sentDemand
    }
}

// MARK: - Private Helpers
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
private extension BorrowedDemandBuffer {
    /// A model that tracks the downstream's
    /// accumulated demand state
    struct Demand {
        var processed: Subscribers.Demand = .none
        var requested: Subscribers.Demand = .none
        var sent: Subscribers.Demand = .none
    }
}

// MARK: - Internally-scoped helpers
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension Subscription {
    /// Reqeust demand if it's not empty
    ///
    /// - parameter demand: Requested demand
    func requestIfNeeded(_ demand: Subscribers.Demand) {
        guard demand > .none else { return }
        request(demand)
    }
}

@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension Optional where Wrapped == Subscription {
    /// Cancel the Optional subscription and nullify it
    mutating func kill() {
        self?.cancel()
        self = nil
    }
}

/// A `ReplaySubject` is a subject that can buffer one or more values. It stores value events, up to its `bufferSize` in a
/// first-in-first-out manner and then replays it to
/// future subscribers and also forwards completion events.
///
/// The implementation borrows heavily from [Entwine’s](https://github.com/tcldr/Entwine/blob/b839c9fcc7466878d6a823677ce608da998b95b9/Sources/Entwine/Operators/ReplaySubject.swift).
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public final class ReplaySubject<Output, Failure: Error>: Subject {
    public typealias Output = Output
    public typealias Failure = Failure

    private let bufferSize: Int
    private var buffer = [Output]()
    public var value: Output {
      get { buffer.first! }
      set { send(newValue) }
    }

    // Keeping track of all live subscriptions, so `send` events can be forwarded to them.
    private var subscriptions = [Subscription<AnySubscriber<Output, Failure>>]()

    private var completion: Subscribers.Completion<Failure>?
    private var isActive: Bool { completion == nil }

    private let lock = NSRecursiveLock()

    /// Create a `ReplaySubject`, buffering up to `bufferSize` values and replaying them to new subscribers
    /// - Parameter bufferSize: The maximum number of value events to buffer and replay to all future subscribers.
    public init(value: Output) {
        self.bufferSize = 1
      self.buffer = [value]
    }

    public func send(_ value: Output) {
        lock.lock()
        defer { lock.unlock() }

        guard isActive else { return }

        buffer.append(value)

        if buffer.count > bufferSize {
            buffer.removeFirst()
        }

        subscriptions.forEach { $0.forwardValueToBuffer(value) }
    }

    public func send(completion: Subscribers.Completion<Failure>) {
        lock.lock()
        defer { lock.unlock() }

        guard isActive else { return }

        self.completion = completion

        subscriptions.forEach { $0.forwardCompletionToBuffer(completion) }
    }

    public func send(subscription: Combine.Subscription) {
        lock.lock()
        defer { lock.unlock() }

        subscription.request(.unlimited)
    }

    public func receive<Subscriber: Combine.Subscriber>(subscriber: Subscriber) where Failure == Subscriber.Failure, Output == Subscriber.Input {
        lock.lock()
        defer { lock.unlock() }
        
        let subscriberIdentifier = subscriber.combineIdentifier

        let subscription = Subscription(downstream: AnySubscriber(subscriber)) { [weak self] in
            guard let self = self,
                  let subscriptionIndex = self.subscriptions
                                              .firstIndex(where: { $0.innerSubscriberIdentifier == subscriberIdentifier }) else { return }

            self.subscriptions.remove(at: subscriptionIndex)
        }

        subscriptions.append(subscription)

        subscriber.receive(subscription: subscription)
        subscription.replay(buffer, completion: completion)
    }
}

@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension ReplaySubject {
    final class Subscription<Downstream: Subscriber>: Combine.Subscription where Output == Downstream.Input, Failure == Downstream.Failure {
        private var demandBuffer: BorrowedDemandBuffer<Downstream>?
        private var cancellationHandler: (() -> Void)?

        fileprivate let innerSubscriberIdentifier: CombineIdentifier

        init(downstream: Downstream, cancellationHandler: (() -> Void)?) {
            self.demandBuffer = BorrowedDemandBuffer(subscriber: downstream)
            self.innerSubscriberIdentifier = downstream.combineIdentifier
            self.cancellationHandler = cancellationHandler
        }

        func replay(_ buffer: [Output], completion: Subscribers.Completion<Failure>?) {
            buffer.forEach(forwardValueToBuffer)

            if let completion = completion {
                forwardCompletionToBuffer(completion)
            }
        }

        func forwardValueToBuffer(_ value: Output) {
            _ = demandBuffer?.buffer(value: value)
        }

        func forwardCompletionToBuffer(_ completion: Subscribers.Completion<Failure>) {
            demandBuffer?.complete(completion: completion)
        }

        func request(_ demand: Subscribers.Demand) {
            _ = demandBuffer?.demand(demand)
        }

        func cancel() {
            cancellationHandler?()
            cancellationHandler = nil

            demandBuffer = nil
        }
    }
}

/// A store represents the runtime that powers the application. It is the object that you will pass
/// around to views that need to interact with the application.
///
/// You will typically construct a single one of these at the root of your application, and then use
/// the `scope` method to derive more focused stores that can be passed to subviews.
public final class Store<State, Action> {
  var state: ReplaySubject<State, Never>
  var effectCancellables: [UUID: AnyCancellable] = [:]
  private var isSending = false
  private var parentCancellable: AnyCancellable?
  private let reducer: (inout State, Action) -> Effect<Action, Never>
  private var synchronousActionsToSend: [Action] = []
  private var bufferedActions: [Action] = []

  /// Initializes a store from an initial state, a reducer, and an environment.
  ///
  /// - Parameters:
  ///   - initialState: The state to start the application in.
  ///   - reducer: The reducer that powers the business logic of the application.
  ///   - environment: The environment of dependencies for the application.
  public convenience init<Environment>(
    initialState: State,
    reducer: Reducer<State, Action, Environment>,
    environment: Environment
  ) {
    self.init(
      initialState: initialState,
      reducer: { reducer.run(&$0, $1, environment) }
    )
  }

  /// Scopes the store to one that exposes local state and actions.
  ///
  /// This can be useful for deriving new stores to hand to child views in an application. For
  /// example:
  ///
  ///     // Application state made from local states.
  ///     struct AppState { var login: LoginState, ... }
  ///     struct AppAction { case login(LoginAction), ... }
  ///
  ///     // A store that runs the entire application.
  ///     let store = Store(
  ///       initialState: AppState(),
  ///       reducer: appReducer,
  ///       environment: AppEnvironment()
  ///     )
  ///
  ///     // Construct a login view by scoping the store to one that works with only login domain.
  ///     LoginView(
  ///       store: store.scope(
  ///         state: { $0.login },
  ///         action: { AppAction.login($0) }
  ///       )
  ///     )
  ///
  /// Scoping in this fashion allows you to better modularize your application. In this case,
  /// `LoginView` could be extracted to a module that has no access to `AppState` or `AppAction`.
  ///
  /// Scoping also gives a view the opportunity to focus on just the state and actions it cares
  /// about, even if its feature domain is larger.
  ///
  /// For example, the above login domain could model a two screen login flow: a login form followed
  /// by a two-factor authentication screen. The second screen's domain might be nested in the
  /// first:
  ///
  ///     struct LoginState: Equatable {
  ///       var email = ""
  ///       var password = ""
  ///       var twoFactorAuth: TwoFactorAuthState?
  ///     }
  ///
  ///     enum LoginAction: Equatable {
  ///       case emailChanged(String)
  ///       case loginButtonTapped
  ///       case loginResponse(Result<TwoFactorAuthState, LoginError>)
  ///       case passwordChanged(String)
  ///       case twoFactorAuth(TwoFactorAuthAction)
  ///     }
  ///
  /// The login view holds onto a store of this domain:
  ///
  ///     struct LoginView: View {
  ///       let store: Store<LoginState, LoginAction>
  ///
  ///       var body: some View { ... }
  ///     }
  ///
  /// If its body were to use a view store of the same domain, this would introduce a number of
  /// problems:
  ///
  /// * The login view would be able to read from `twoFactorAuth` state. This state is only intended
  ///   to be read from the two-factor auth screen.
  ///
  /// * Even worse, changes to `twoFactorAuth` state would now cause SwiftUI to recompute
  ///   `LoginView`'s body unnecessarily.
  ///
  /// * The login view would be able to send `twoFactorAuth` actions. These actions are only
  ///   intended to be sent from the two-factor auth screen (and reducer).
  ///
  /// * The login view would be able to send non user-facing login actions, like `loginResponse`.
  ///   These actions are only intended to be used in the login reducer to feed the results of
  ///   effects back into the store.
  ///
  /// To avoid these issues, one can introduce a view-specific domain that slices off the subset of
  /// state and actions that a view cares about:
  ///
  ///     extension LoginView {
  ///       struct State: Equatable {
  ///         var email: String
  ///         var password: String
  ///       }
  ///
  ///       enum Action: Equatable {
  ///         case emailChanged(String)
  ///         case loginButtonTapped
  ///         case passwordChanged(String)
  ///       }
  ///     }
  ///
  /// One can also introduce a couple helpers that transform feature state into view state and
  /// transform view actions into feature actions.
  ///
  ///     extension LoginState {
  ///       var view: LoginView.State {
  ///         .init(email: self.email, password: self.password)
  ///       }
  ///     }
  ///
  ///     extension LoginView.Action {
  ///       var feature: LoginAction {
  ///         switch self {
  ///         case let .emailChanged(email)
  ///           return .emailChanged(email)
  ///         case .loginButtonTapped:
  ///           return .loginButtonTapped
  ///         case let .passwordChanged(password)
  ///           return .passwordChanged(password)
  ///         }
  ///       }
  ///     }
  ///
  /// With these helpers defined, `LoginView` can now scope its store's feature domain into its view
  /// domain:
  ///
  ///     var body: some View {
  ///       WithViewStore(
  ///         self.store.scope(state: { $0.view }, action: { $0.feature })
  ///       ) { viewStore in
  ///         ...
  ///       }
  ///     }
  ///
  /// This view store is now incapable of reading any state but view state (and will not recompute
  /// when non-view state changes), and is incapable of sending any actions but view actions.
  ///
  /// - Parameters:
  ///   - toLocalState: A function that transforms `State` into `LocalState`.
  ///   - fromLocalAction: A function that transforms `LocalAction` into `Action`.
  /// - Returns: A new store with its domain (state and action) transformed.
  public func scope<LocalState, LocalAction>(
    state toLocalState: @escaping (State) -> LocalState,
    action fromLocalAction: @escaping (LocalAction) -> Action
  ) -> Store<LocalState, LocalAction> {
    let localStore = Store<LocalState, LocalAction>(
      initialState: toLocalState(self.state.value),
      reducer: { localState, localAction in
        self.send(fromLocalAction(localAction))
        localState = toLocalState(self.state.value)
        return .none
      }
    )
    localStore.parentCancellable = self.state
      .sink { [weak localStore] newValue in localStore?.state.value = toLocalState(newValue) }
    return localStore
  }

  /// Scopes the store to one that exposes local state.
  ///
  /// - Parameter toLocalState: A function that transforms `State` into `LocalState`.
  /// - Returns: A new store with its domain (state and action) transformed.
  public func scope<LocalState>(
    state toLocalState: @escaping (State) -> LocalState
  ) -> Store<LocalState, Action> {
    self.scope(state: toLocalState, action: { $0 })
  }

  /// Scopes the store to a publisher of stores of more local state and local actions.
  ///
  /// - Parameters:
  ///   - toLocalState: A function that transforms a publisher of `State` into a publisher of
  ///     `LocalState`.
  ///   - fromLocalAction: A function that transforms `LocalAction` into `Action`.
  /// - Returns: A publisher of stores with its domain (state and action) transformed.
  public func publisherScope<P: Publisher, LocalState, LocalAction>(
    state toLocalState: @escaping (AnyPublisher<State, Never>) -> P,
    action fromLocalAction: @escaping (LocalAction) -> Action
  ) -> AnyPublisher<Store<LocalState, LocalAction>, Never>
  where P.Output == LocalState, P.Failure == Never {

    func extractLocalState(_ state: State) -> LocalState? {
      var localState: LocalState?
      _ = toLocalState(Just(state).eraseToAnyPublisher())
        .sink { localState = $0 }
      return localState
    }

    return toLocalState(self.state.eraseToAnyPublisher())
      .map { localState in
        let localStore = Store<LocalState, LocalAction>(
          initialState: localState,
          reducer: { localState, localAction in
            self.send(fromLocalAction(localAction))
            localState = extractLocalState(self.state.value) ?? localState
            return .none
          })

        localStore.parentCancellable = self.state
          .sink { [weak localStore] state in
            guard let localStore = localStore else { return }
            localStore.state.value = extractLocalState(state) ?? localStore.state.value
          }
        return localStore
      }
      .eraseToAnyPublisher()
  }

  /// Scopes the store to a publisher of stores of more local state and local actions.
  ///
  /// - Parameter toLocalState: A function that transforms a publisher of `State` into a publisher
  ///   of `LocalState`.
  /// - Returns: A publisher of stores with its domain (state and action)
  ///   transformed.
  public func publisherScope<P: Publisher, LocalState>(
    state toLocalState: @escaping (AnyPublisher<State, Never>) -> P
  ) -> AnyPublisher<Store<LocalState, Action>, Never>
  where P.Output == LocalState, P.Failure == Never {
    self.publisherScope(state: toLocalState, action: { $0 })
  }

  func send(_ action: Action) {
    if !self.isSending {
      self.synchronousActionsToSend.append(action)
    } else {
      self.bufferedActions.append(action)
      return
    }

    while !self.synchronousActionsToSend.isEmpty || !self.bufferedActions.isEmpty {
      let action =
        !self.synchronousActionsToSend.isEmpty
        ? self.synchronousActionsToSend.removeFirst()
        : self.bufferedActions.removeFirst()

      self.isSending = true
      let effect = self.reducer(&self.state.value, action)
      self.isSending = false

      var didComplete = false
      let uuid = UUID()

      var isProcessingEffects = true
      let effectCancellable = effect.sink(
        receiveCompletion: { [weak self] _ in
          didComplete = true
          self?.effectCancellables[uuid] = nil
        },
        receiveValue: { [weak self] action in
          if isProcessingEffects {
            self?.synchronousActionsToSend.append(action)
          } else {
            self?.send(action)
          }
        }
      )
      isProcessingEffects = false

      if !didComplete {
        self.effectCancellables[uuid] = effectCancellable
      }
    }
  }

  /// Returns a "stateless" store by erasing state to `Void`.
  public var stateless: Store<Void, Action> {
    self.scope(state: { _ in () })
  }

  /// Returns an "actionless" store by erasing action to `Never`.
  public var actionless: Store<State, Never> {
    func absurd<A>(_ never: Never) -> A {}
    return self.scope(state: { $0 }, action: absurd)
  }

  private init(
    initialState: State,
    reducer: @escaping (inout State, Action) -> Effect<Action, Never>
  ) {
    self.reducer = reducer
    self.state = ReplaySubject(value: initialState) // CurrentValueSubject(initialState)
  }
}

/// A publisher of store state.
@dynamicMemberLookup
public struct StorePublisher<State>: Publisher {
  public typealias Output = State
  public typealias Failure = Never

  public let upstream: AnyPublisher<State, Never>

  public func receive<S>(subscriber: S)
  where S: Subscriber, Failure == S.Failure, Output == S.Input {
    self.upstream.subscribe(subscriber)
  }

  init<P>(_ upstream: P) where P: Publisher, Failure == P.Failure, Output == P.Output {
    self.upstream = upstream.eraseToAnyPublisher()
  }

  /// Returns the resulting publisher of a given key path.
  public subscript<LocalState>(
    dynamicMember keyPath: KeyPath<State, LocalState>
  ) -> StorePublisher<LocalState>
  where LocalState: Equatable {
    .init(self.upstream.map(keyPath).removeDuplicates())
  }
}
