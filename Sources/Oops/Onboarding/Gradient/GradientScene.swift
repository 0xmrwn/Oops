import simd

/// ShaderGradient's props, as its React component takes them (degrees, hex colours), for the parts this
/// port covers: the "defaults" sphere lit by the "city" environment, with `grain="off"`.
struct ShaderGradient: Equatable {
    var color1 = SIMD3<Float>(0x73, 0xbf, 0xc4) / 255
    var color2 = SIMD3<Float>(0xff, 0x81, 0x0a) / 255
    var color3 = SIMD3<Float>(0x8d, 0xa0, 0xce) / 255
    var cAzimuthAngle = 270.0, cPolarAngle = 180.0, cameraZoom = 15.1, fov = 45.0
    var position = SIMD3<Double>(-0.1, 0, 0)
    var rotation = SIMD3<Double>(0, 130, 70)
    var reflection: Float = 0.4
    var uAmplitude: Float = 3.2, uDensity: Float = 0.8, uFrequency: Float = 5.5, uSpeed: Float = 0.3, uStrength: Float = 0.3
    var uTime: Float = 0
    var animate = true

    /// Hello's desktop.
    static let hello = ShaderGradient()
}

/// three.js's scene for a ShaderGradient sphere, computed as three computes it: the mesh's matrix, the
/// camera camera-controls settles on, and its projection.
enum GradientScene {
    /// The sphere's camera distance (consts.ts `defaultSphereDistance`); `cDistance` applies to planes only.
    static let distance = 14.0
    static let near = 0.1, far = 1000.0

    /// `Object3D.matrix` from position and an XYZ Euler rotation (`Matrix4.makeRotationFromEuler`).
    static func model(_ gradient: ShaderGradient) -> simd_double4x4 {
        let r = gradient.rotation * .pi / 180
        let a = cos(r.x), b = sin(r.x), c = cos(r.y), d = sin(r.y), e = cos(r.z), f = sin(r.z)
        let ae = a * e, af = a * f, be = b * e, bf = b * f
        return simd_double4x4(columns: (SIMD4(c * e, af + be * d, bf - ae * d, 0), SIMD4(-c * f, ae - bf * d, be + af * d, 0),
                                        SIMD4(d, -b * c, a * c, 0), SIMD4(gradient.position, 1)))
    }

    /// camera-controls' spherical position around the origin (`Spherical.makeSafe` keeps the pole off by
    /// 1e-6), then `Matrix4.lookAt` with three's default up, inverted.
    static func view(_ gradient: ShaderGradient) -> simd_double4x4 {
        let eps = 0.000001
        let phi = max(eps, min(.pi - eps, gradient.cPolarAngle * .pi / 180)), theta = gradient.cAzimuthAngle * .pi / 180
        let eye = SIMD3(distance * sin(phi) * sin(theta), distance * cos(phi), distance * sin(phi) * cos(theta))
        let z = normalize(eye)
        let x = normalize(cross(SIMD3(0, 1, 0), z))
        let y = cross(z, x)
        return simd_double4x4(rows: [SIMD4(x, -dot(x, eye)), SIMD4(y, -dot(y, eye)), SIMD4(z, -dot(z, eye)), SIMD4(0, 0, 0, 1)])
    }

    /// `PerspectiveCamera.updateProjectionMatrix` with its zoom, mapped to Metal's 0…1 depth.
    static func projection(_ gradient: ShaderGradient, aspect: Double) -> simd_double4x4 {
        let top = near * tan(gradient.fov * .pi / 180 * 0.5) / gradient.cameraZoom
        let height = 2 * top, width = aspect * height
        return simd_double4x4(rows: [SIMD4(2 * near / width, 0, 0, 0), SIMD4(0, 2 * near / height, 0, 0),
                                     SIMD4(0, 0, -far / (far - near), -far * near / (far - near)), SIMD4(0, 0, -1, 0)])
    }

    /// three's `IcosahedronGeometry(1, 64)` with the original triangle order. Each face keeps its
    /// own grid so its interpolated positions retain the same rounding at face edges.
    static func sphere() -> (vertices: [Float], indices: [UInt16]) {
        let columns = 65, floatsPerVertex = 8
        let t = (1 + 5.0.squareRoot()) / 2
        let corners: [SIMD3<Double>] = [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
                                        [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]]
        let faces = [0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
                     3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1]
        func lerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ alpha: Double) -> SIMD3<Double> { a + (b - a) * alpha }

        var vertices: [Float] = []
        var indices: [UInt16] = []
        // There are 44,220 vertices across the 20 face grids, within the 16-bit index range.
        vertices.reserveCapacity(faces.count / 3 * (columns + 1) * (columns + 2) / 2 * floatsPerVertex)
        indices.reserveCapacity(faces.count * columns * columns)
        for face in stride(from: 0, to: faces.count, by: 3) {
            let a = corners[faces[face]], b = corners[faces[face + 1]], c = corners[faces[face + 2]]
            for i in 0...columns {
                let start = UInt16(vertices.count / floatsPerVertex)
                let left = lerp(a, c, Double(i) / Double(columns)), right = lerp(b, c, Double(i) / Double(columns))
                let segments = columns - i
                for j in 0...segments {
                    let raw = i == columns ? left : lerp(left, right, Double(j) / Double(segments))
                    let position = raw * (1 / length(raw))
                    let stored = SIMD3<Float>(position)
                    // `normalizeNormals` runs on the stored single-precision positions.
                    let normal = SIMD3<Float>(SIMD3<Double>(stored) * (1 / length(SIMD3<Double>(stored))))
                    let inclination = atan2(-position.y, (position.x * position.x + position.z * position.z).squareRoot())
                    // Keep the shader's vertex layout. It reads UV y, so UV x needs no seam correction.
                    let latitude = Float(1 - (inclination / .pi + 0.5))
                    vertices += [stored.x, stored.y, stored.z, normal.x, normal.y, normal.z, 0, latitude]
                }
                let segmentCount = UInt16(segments), next = start + segmentCount + 1
                for j in 0..<segmentCount {
                    indices += [start + j + 1, next + j, start + j]
                    if j + 1 < segmentCount { indices += [start + j + 1, next + j + 1, next + j] }
                }
            }
        }
        return (vertices, indices)
    }
}
