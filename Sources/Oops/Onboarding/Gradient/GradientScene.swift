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

    /// `IcosahedronGeometry(1, 64)`, vertex for vertex: non-indexed triangles, each vertex its position,
    /// normal and uv (8 floats), with three's seam and pole corrections to the uvs.
    static func sphere(detail: Int = 64) -> [Float] {
        let t = (1 + 5.0.squareRoot()) / 2
        let corners: [SIMD3<Double>] = [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
                                        [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]]
        let indices = [0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
                       3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1]
        func lerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ alpha: Double) -> SIMD3<Double> { a + (b - a) * alpha }

        var positions: [SIMD3<Double>] = []
        positions.reserveCapacity(indices.count / 3 * (detail + 1) * (detail + 1) * 3)
        for face in stride(from: 0, to: indices.count, by: 3) {
            let a = corners[indices[face]], b = corners[indices[face + 1]], c = corners[indices[face + 2]]
            let cols = detail + 1
            var v: [[SIMD3<Double>]] = []
            for i in 0...cols {
                let aj = lerp(a, c, Double(i) / Double(cols)), bj = lerp(b, c, Double(i) / Double(cols)), rows = cols - i
                v.append((0...rows).map { j in j == 0 && i == cols ? aj : lerp(aj, bj, Double(j) / Double(rows)) })
            }
            for i in 0..<cols {
                for j in 0..<(2 * (cols - i) - 1) {
                    let k = j / 2
                    if j.isMultiple(of: 2) { positions += [v[i][k + 1], v[i + 1][k], v[i][k]] }
                    else { positions += [v[i][k + 1], v[i + 1][k + 1], v[i + 1][k]] }
                }
            }
        }
        positions = positions.map { $0 * (1 / length($0)) } // Radius 1.

        func azimuth(_ v: SIMD3<Double>) -> Double { atan2(v.z, -v.x) }
        func inclination(_ v: SIMD3<Double>) -> Double { atan2(-v.y, (v.x * v.x + v.z * v.z).squareRoot()) }
        var uvs = positions.map { SIMD2(azimuth($0) / 2 / .pi + 0.5, 1 - (inclination($0) / .pi + 0.5)) }
        for triangle in stride(from: 0, to: positions.count, by: 3) {
            let centroid = (positions[triangle] + positions[triangle + 1] + positions[triangle + 2]) * (1.0 / 3)
            let azi = azimuth(centroid)
            for index in triangle..<triangle + 3 {
                let uv = uvs[index], vector = positions[index]
                if azi < 0, uv.x == 1 { uvs[index].x = uv.x - 1 }
                if vector.x == 0, vector.z == 0 { uvs[index].x = azi / 2 / .pi + 0.5 }
            }
            let xs = [uvs[triangle].x, uvs[triangle + 1].x, uvs[triangle + 2].x]
            if xs.max()! > 0.9, xs.min()! < 0.1 {
                for index in triangle..<triangle + 3 where uvs[index].x < 0.2 { uvs[index].x += 1 }
            }
        }

        var vertices: [Float] = []
        vertices.reserveCapacity(positions.count * 8)
        for (position, uv) in zip(positions, uvs) {
            let stored = SIMD3<Float>(position)
            // `normalizeNormals` on the stored (single-precision) copy of the positions.
            let normal = SIMD3<Float>(SIMD3<Double>(stored) * (1 / length(SIMD3<Double>(stored))))
            vertices += [stored.x, stored.y, stored.z, normal.x, normal.y, normal.z, Float(uv.x), Float(uv.y)]
        }
        return vertices
    }
}
