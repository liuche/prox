/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Deferred

private let ratingWeight: Float = 1
private let reviewWeight: Float = 2

struct PlaceUtilities {

    private static let MaxDisplayedCategories = 3 // via #54

    static func sort(places: [Place], byDistanceFromLocation location: CLLocation, ascending: Bool = true) -> [Place] {
        return places.sorted { (placeA, placeB) -> Bool in
            let placeADistance = location.distance(from: CLLocation(latitude: placeA.latLong.latitude, longitude: placeA.latLong.longitude))
            let placeBDistance = location.distance(from: CLLocation(latitude: placeB.latLong.latitude, longitude: placeB.latLong.longitude))

            if ascending {
                return placeADistance < placeBDistance
            }

            return placeADistance > placeBDistance
        }
    }

    static func sort(places: [Place], byTravelTimeFromLocation location: CLLocation, ascending: Bool = true, completion: @escaping ([Place]) -> ()) {
        var sortedPlaces = PlaceUtilities.sort(places: places, byDistanceFromLocation: location)
        // this means we will probably only get walking directions for places, but I think that will be OK for now
        PlaceUtilities.updateTravelTimes(forPlaces: sortedPlaces, fromLocation: location, withTransitTypes: [.walking]).upon {
            let sortedByTravelTime = places.sorted { (placeA, placeB) -> Bool in
                let placeAETA = PlaceUtilities.lastTravelTimes(forPlace: placeA)?.getShortestTravelTime() ?? Double.greatestFiniteMagnitude
                let placeBETA = PlaceUtilities.lastTravelTimes(forPlace: placeB)?.getShortestTravelTime() ?? Double.greatestFiniteMagnitude

                if ascending {
                    return placeAETA <= placeBETA
                } else {
                    return placeAETA >= placeBETA
                }
            }

            for (index, place) in sortedByTravelTime.enumerated() {
                sortedPlaces[index] = place
            }
            completion(sortedPlaces)
        }
    }

    static func sortByTopRated(places: [Place]) -> [Place] {
        let maxReviews = places.map { $0.totalReviewCount }.max() ?? 0
        let logMaxReviews = log10(Float(maxReviews))

        return places.sorted { a, b in
            return proxRating(forPlace: a, logMaxReviews: logMaxReviews) > proxRating(forPlace: b, logMaxReviews: logMaxReviews)
        }
    }

    private static func updateTravelTimes(forPlaces places: [Place], fromLocation location: CLLocation, withTransitTypes transitTypes: [MKDirectionsTransportType]) -> Future<Void> {
        // HACK: travelTimes(fromLocation: location) may not fill its Deferred due to an apparent bug where
        // MKDirections.calculateETA() never executes its callback. We set a timeout as a workaround.
        return places.map { $0.travelTimes(fromLocation: location, withTransitTypes: transitTypes) }.allFilled().timeout(deadline: .now() + 5).ignored()
    }

    private static func lastTravelTimes(forPlace place: Place) -> TravelTimes? {
        guard let (deferred, _) = Place.travelTimesCache[place.id],
        let result = deferred.peek() else {
            return nil
        }
        return result.successResult()
    }

    /// Returns a number from 0-1 that weighs different properties on the place.
    private static func proxRating(forPlace place: Place, logMaxReviews: Float) -> Float {
        let yelpCount = Float(place.yelpProvider.totalReviewCount)
        let taCount = Float(place.tripAdvisorProvider?.totalReviewCount ?? 0)
        let yelpRating = place.yelpProvider.rating ?? 0
        let taRating = place.tripAdvisorProvider?.rating ?? 0
        let ratingScore = (yelpRating * yelpCount + taRating * taCount) / (yelpCount + taCount) / 5
        let reviewScore = log10(yelpCount + taCount) / logMaxReviews
        return (ratingScore * ratingWeight + reviewScore * reviewWeight) / (ratingWeight + reviewWeight)
    }

    static func filter(places: [Place], withFilters enabledFilters: Set<PlaceFilter>) -> [Place] {
        return places.filter { place in
            // If the place has listed times but won't be open in the near future, skip it.
            let now = Date()
            if let hours = place.hours, !hours.isOpen(atTime: now), hours.nextOpeningTime(forTime: now) == nil { return false }

            let filter: PlaceFilter
            if place.id.hasPrefix(AppConstants.testPrefixDiscover) {
                filter = .services
            } else if place.id.hasPrefix(AppConstants.testPrefixEvent) {
                filter = .localevents
            } else {
                guard let firstFilter = place.categories.ids.flatMap({ CategoriesUtil.categoryToFilter[$0] }).first else { return false }
                filter = firstFilter
            }
            return enabledFilters.contains(filter)
        }
    }

    static func getString(forCategories categories: [String]?) -> String? {
        return categories?.prefix(MaxDisplayedCategories).joined(separator: " • ")
    }

    static func updateReviewUI(fromProvider provider: PlaceProvider?, onView view: ReviewContainerView, isTextShortened: Bool = false) {
        guard let provider = provider,
                !(provider.totalReviewCount == 0 && provider.rating == nil) else { // intentional: if both null, short-circuit
            setSubviewAlpha(0.4, forParent: view)
            view.score = 0
            view.numberOfReviewersLabel.text = "No info" + (isTextShortened ? "" : " available")
            return
        }

        setSubviewAlpha(1.0, forParent: view)

        if let rating = provider.rating {
            view.score = rating
        } else {
            view.reviewScore.alpha = 0.15 // no UX spec so I eyeballed. Unlikely anyway.
            view.score = 0
        }

        let reviewPrefix: String
        if provider.totalReviewCount > 0 { reviewPrefix = String(provider.totalReviewCount) }
        else { reviewPrefix = "No" }
        view.numberOfReviewersLabel.text = reviewPrefix + " Reviews"
    }

    // assumes called from UI thread.
    static func updateTravelTimeUI(fromPlace place: Place, toLocation location: CLLocation?, forView view: TravelTimesView) {
        view.prepareTravelTimesUIForReuse()

        guard let location = location else {
            // TODO: how to handle? Previously, this was unhandled.
            return
        }

        // TODO: need to cancel long running requests or users may be stuck with a loading spinner
        // rather than a "View on Map" button. I think this only happens when you swipe real fast.
        let travelTimesResult = place.travelTimes(fromLocation: location)
        if !travelTimesResult.isFilled {
            view.setTravelTimesUIIsLoading(true)
        }

        let idAtCallTime = place.id
        view.setIDForTravelTimesView(idAtCallTime)
        travelTimesResult.upon(DispatchQueue.main) { res in
            guard let idAtResultTime = view.getIDForTravelTimesView(), // should never be nil
                    idAtCallTime == idAtResultTime else {
                // Someone has requested new travel times for this view (re-used?) before we could
                // display the result: cancel view update.
                return
            }

            view.setTravelTimesUIIsLoading(false)

            guard let travelTimes = res.successResult() else {
                view.updateTravelTimesUIForResult(.noData, durationInMinutes: nil)
                return
            }

            if let walkingTimeSeconds = travelTimes.walkingTime {
                let walkingTimeMinutes = Int(round(walkingTimeSeconds / 60.0))
                if walkingTimeMinutes <= TravelTimesProvider.MIN_WALKING_TIME {
                    if walkingTimeMinutes < TravelTimesProvider.YOU_ARE_HERE_WALKING_TIME {
                        view.updateTravelTimesUIForResult(.userHere, durationInMinutes: nil)
                    } else {
                        view.updateTravelTimesUIForResult(.walkingDist, durationInMinutes: walkingTimeMinutes)
                    }
                    return
                }
            }

            if let drivingTimeSeconds = travelTimes.drivingTime {
                let drivingTimeMinutes = Int(round(drivingTimeSeconds / 60.0))
                view.updateTravelTimesUIForResult(.drivingDist, durationInMinutes: drivingTimeMinutes)
                return
            }

            view.updateTravelTimesUIForResult(.noData, durationInMinutes: nil)
        }
    }

    private static func setSubviewAlpha(_ alpha: CGFloat, forParent parentView: ReviewContainerView) {
        for view in parentView.subviews {
            view.alpha = alpha
        }
    }
}
