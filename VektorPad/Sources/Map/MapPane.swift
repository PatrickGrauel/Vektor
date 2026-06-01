import SwiftUI
import MapKit
import VektorEngine

/// Interactive airport map with a live METAR overlay. Pins are colored by
/// flight category (VFR / MVFR / IFR / LIFR); panning/zooming refetches the
/// visible bounding box from MetarService. Tap a pin for the raw report.
struct MapPane: View {
    var body: some View {
        MetarMap()
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottomLeading) { legend }
            .navigationTitle("METAR Map")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(.green, "VFR")
            legendRow(.blue, "MVFR")
            legendRow(.red, "IFR")
            legendRow(.purple, "LIFR")
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(14)
    }

    private func legendRow(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.primary)
        }
    }
}

private final class MetarAnnotation: MKPointAnnotation {
    var fltCat: MetarService.BBoxStation.FltCat = .unknown
}

private struct MetarMap: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        // Default view over central Europe (around EDDM).
        map.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 48.35, longitude: 11.78),
            latitudinalMeters: 700_000, longitudinalMeters: 700_000), animated: false)
        context.coordinator.map = map
        context.coordinator.scheduleFetch()
        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var map: MKMapView?
        private var fetchTask: Task<Void, Never>?

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            scheduleFetch()
        }

        func scheduleFetch() {
            fetchTask?.cancel()
            fetchTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let map else { return }
                let r = map.region
                // Skip continent-sized boxes — the endpoint caps results
                // and the pins would be meaningless that far out.
                guard r.span.latitudeDelta < 25, r.span.longitudeDelta < 25 else {
                    map.removeAnnotations(map.annotations)
                    return
                }
                let minLat = r.center.latitude - r.span.latitudeDelta / 2
                let maxLat = r.center.latitude + r.span.latitudeDelta / 2
                let minLon = r.center.longitude - r.span.longitudeDelta / 2
                let maxLon = r.center.longitude + r.span.longitudeDelta / 2
                let stations = (try? await MetarService.shared.metarsInBBox(
                    minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)) ?? []
                if Task.isCancelled { return }
                self.apply(stations)
            }
        }

        @MainActor
        private func apply(_ stations: [MetarService.BBoxStation]) {
            guard let map else { return }
            map.removeAnnotations(map.annotations)
            let anns = stations.prefix(250).map { s -> MetarAnnotation in
                let a = MetarAnnotation()
                a.coordinate = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
                a.title = s.icao
                a.subtitle = s.raw
                a.fltCat = s.fltCat
                return a
            }
            map.addAnnotations(anns)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let m = annotation as? MetarAnnotation else { return nil }
            let id = "metar"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.markerTintColor = Self.color(for: m.fltCat)
            view.canShowCallout = true
            view.titleVisibility = .hidden
            view.displayPriority = .defaultLow   // let MapKit declutter
            return view
        }

        private static func color(for cat: MetarService.BBoxStation.FltCat) -> UIColor {
            switch cat {
            case .vfr:     return .systemGreen
            case .mvfr:    return .systemBlue
            case .ifr:     return .systemRed
            case .lifr:    return .systemPurple
            case .unknown: return .systemGray
            }
        }
    }
}
