/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import AFNetworking
import Deferred
import FirebaseRemoteConfig
import Foundation

/*
 * Delegate methods for updating places asynchronously.
 * All methods on the delegate will be called on the main thread.
 */
protocol PlacesProviderDelegate: class {
    func placesProvider(_ controller: PlacesProvider, didUpdatePlaces places: [Place])
}

class PlacesProvider {
    weak var delegate: PlacesProviderDelegate?

    private let database = FirebasePlacesDatabase()

    private lazy var radius: Double = {
        return RemoteConfigKeys.searchRadiusInKm.value
    }()

    /// The collection of all fetched places sorted by travel times (up until rate limiting).
    private var allPlaces = [Place]()

    /// The collection of places displayed to the user.
    private var displayedPlaces = [Place]() {
        didSet {
            var placesMap = [String: Int]()
            for (index, place) in displayedPlaces.enumerated() {
                placesMap[place.id] = index
            }
            placeKeyToDisplayedPlacesIndexMap = placesMap
        }
    }

    /// A mapping from place key to index in `displayedPlaces` - this must update when
    /// `displayedPlaces` does.
    fileprivate var placeKeyToDisplayedPlacesIndexMap = [String: Int]()

    /// Protects allPlaces, displayedPlaces, and placeKeyMap.
    fileprivate let placesLock = NSLock()

    private(set) var enabledFilters: Set<PlaceFilter> = Set([ .discover, .localevents ])
    private(set) var topRatedOnly = false

    init() {}

    // only accessible for tests.
    convenience init(places: [Place]) {
        self.init()
        self.displayedPlaces = places
        var placesMap = [String: Int]()
        for (index, place) in displayedPlaces.enumerated() {
            placesMap[place.id] = index
        }
        self.placeKeyToDisplayedPlacesIndexMap = placesMap
    }

    func place(forKey key: String, callback: @escaping (Place?) -> ()) {
        database.getPlace(forKey: key).upon { callback($0.successResult() )}
    }

    func updatePlaces(forLocation location: CLLocation) {
        let places = database.getPlaces(forLocation: location, withRadius: radius)
        let events = Eventbrite.searchEvents(near: location.coordinate) // TODO: timeout?
        places.and(events).upon { placesResult, eventsResult in
            let places = placesResult.flatMap { $0.successResult() }
            let placesToDisplay: [Place]
            if let events = eventsResult.successResult() {
                // HACK: for now, it's easier to make the events into fake places than
                // figure out an extensible way to merge the two.
                placesToDisplay = places + events.flatMap { $0.toPlace() }
            } else {
                // TODO: handle error for missing places?
                placesToDisplay = places
            }
            self.displayPlaces(places: placesToDisplay, forLocation: location)
        }
    }

    /// Applies the current set of filters to all places, setting `displayedPlaces` to the result.
    /// Callers must acquire a write lock before calling this method!
    fileprivate func updateDisplayedPlaces() {
        let filteredPlaces = PlaceUtilities.filter(places: allPlaces, withFilters: enabledFilters)
        let sortedPlaces: [Place]
        if topRatedOnly {
            sortedPlaces = PlaceUtilities.sortByTopRated(places: filteredPlaces)
        } else {
            sortedPlaces = filteredPlaces // allPlaces is already sorted.
        }
        displayedPlaces = sortedPlaces
    }

    private func displayPlaces(places: [Place], forLocation location: CLLocation) {
        // HACK (#584): we want the initial set of places the user sees to have travel times. However,
        // our implementation sorts *all* the places, so we're rate limited on some of the places the
        // user will actually see. Here, we force load the travel times for the places the user will
        // see first, before we're rate limited in the final sort (note: these travel times will cache).
        //
        // A proper implementation would sort only the places the user will see (#605) but I don't
        // have time to implement that.
        let placesUserWillSee = PlaceUtilities.filter(places: places, withFilters: enabledFilters)
        PlaceUtilities.sort(places: placesUserWillSee, byTravelTimeFromLocation: location) { places in }

        return PlaceUtilities.sort(places: places, byTravelTimeFromLocation: location, ascending: true, completion: { sortedPlaces in
            let newDisplayedPlaces = self.placesLock.withWriteLock { () -> [Place] in
                self.allPlaces = sortedPlaces
                self.updateDisplayedPlaces()
                return self.displayedPlaces
            }

            DispatchQueue.main.async {
                self.delegate?.placesProvider(self, didUpdatePlaces: newDisplayedPlaces)
            }
        })
    }

    func nextPlace(forPlace place: Place) -> Place? {
        return self.placesLock.withReadLock {
            // if the place isn't in the list, make the first item in the list the next item
            guard let currentPlaceIndex = self.placeKeyToDisplayedPlacesIndexMap[place.id] else {
                return displayedPlaces.count > 0 ? displayedPlaces[displayedPlaces.startIndex] : nil
            }

            guard currentPlaceIndex + 1 < displayedPlaces.endIndex else { return nil }

            return displayedPlaces[displayedPlaces.index(after: currentPlaceIndex)]
        }
    }

    func previousPlace(forPlace place: Place) -> Place? {
        return self.placesLock.withReadLock {
            guard let currentPlaceIndex = self.placeKeyToDisplayedPlacesIndexMap[place.id],
                currentPlaceIndex > displayedPlaces.startIndex else { return nil }

            return displayedPlaces[displayedPlaces.index(before: currentPlaceIndex)]
        }
    }

    func numberOfPlaces() -> Int {
        return self.placesLock.withReadLock {
            return displayedPlaces.count
        }
    }

    func place(forIndex index: Int) throws -> Place {
        return try self.placesLock.withReadLock {
            guard index < displayedPlaces.endIndex,
                index >= displayedPlaces.startIndex else {
                    throw PlaceDataSourceError(message: "There is no place at index: \(index)")
            }

            return displayedPlaces[index]
        }
    }

    func index(forPlace place: Place) -> Int? {
        return self.placesLock.withReadLock {
            return placeKeyToDisplayedPlacesIndexMap[place.id]
        }
    }

    func sortPlaces(byLocation location: CLLocation) {
        self.placesLock.withWriteLock {
            guard !topRatedOnly else { return }
            let sortedPlaces = PlaceUtilities.sort(places: displayedPlaces, byDistanceFromLocation: location)
            self.displayedPlaces = sortedPlaces
        }
    }

    func refresh(enabledFilters: Set<PlaceFilter>, topRatedOnly: Bool) {
        assert(Thread.isMainThread)

        let newDisplayedPlaces = placesLock.withWriteLock { () -> [Place] in
            self.enabledFilters = enabledFilters
            self.topRatedOnly = topRatedOnly
            updateDisplayedPlaces()
            return self.displayedPlaces
        }

        delegate?.placesProvider(self, didUpdatePlaces: newDisplayedPlaces)
    }

    /// Gets all internal place representations, atomically.
    func getPlaces() -> (allPlaces: [Place], displayedPlaces: [Place]) {
        return placesLock.withReadLock {
            return (allPlaces, displayedPlaces)
        }
    }
}
