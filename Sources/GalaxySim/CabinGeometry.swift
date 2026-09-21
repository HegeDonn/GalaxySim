import simd

/// Ship-local, metre-scale interior. The seated eye is at the origin, looking down -Z.
struct CabinVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var color: SIMD4<Float>
    var detail: SIMD4<Float>
}

enum CabinGeometry {
    static func makeVertices() -> [CabinVertex] {
        var model = Builder()
        model.build()
        return model.vertices
    }

    private struct Builder {
        var vertices: [CabinVertex] = []
        let dark = SIMD3<Float>(0.045, 0.061, 0.075)
        let alloy = SIMD3<Float>(0.12, 0.16, 0.18)
        let edge = SIMD3<Float>(0.23, 0.28, 0.29)
        let amber = SIMD3<Float>(1.0, 0.44, 0.13)
        let cyan = SIMD3<Float>(0.19, 0.85, 1.0)
        let ix = SIMD3<Float>(1, 0, 0)
        let iy = SIMD3<Float>(0, 1, 0)
        let iz = SIMD3<Float>(0, 0, 1)

        mutating func polygon(_ points: [SIMD3<Float>], normal: SIMD3<Float>, color: SIMD3<Float>, kind: Float = 0) {
            guard points.count >= 3 else { return }
            for i in 1..<(points.count - 1) {
                var tri = [points[0], points[i], points[i + 1]]
                if simd_dot(simd_cross(tri[1] - tri[0], tri[2] - tri[0]), normal) < 0 { tri.swapAt(1, 2) }
                for p in tri { vertices.append(CabinVertex(position: SIMD4(p, 1), normal: SIMD4(normal, 0), color: SIMD4(color, 1), detail: SIMD4(kind, 0, 0, 0))) }
            }
        }

        /// Actual chamfered geometry, including corner triangles, instead of razor-edged cubes.
        mutating func box(_ center: SIMD3<Float>, _ size: SIMD3<Float>, _ color: SIMD3<Float>, bevel: Float = 0.015, kind: Float = 0, x: SIMD3<Float>? = nil, y: SIMD3<Float>? = nil, z: SIMD3<Float>? = nil) {
            let basis = [x ?? ix, y ?? iy, z ?? iz]
            let h = size * 0.5
            let b = min(bevel, min(h.x, min(h.y, h.z)) * 0.8)
            func world(_ p: SIMD3<Float>) -> SIMD3<Float> { center + basis[0] * p.x + basis[1] * p.y + basis[2] * p.z }
            func face(_ local: [SIMD3<Float>], _ n: SIMD3<Float>) -> ([SIMD3<Float>], SIMD3<Float>) {
                (local.map(world), simd_normalize(basis[0] * n.x + basis[1] * n.y + basis[2] * n.z))
            }
            for a in 0..<3 {
                let u = (a + 1) % 3, v = (a + 2) % 3
                for s: Float in [-1, 1] {
                    var pts: [SIMD3<Float>] = []
                    let outline: [(Float,Float)] = [(-h[u]+b,-h[v]+b),(h[u]-b,-h[v]+b),(h[u]-b,h[v]-b),(-h[u]+b,h[v]-b)]
                    for (pu,pv) in outline { var p = SIMD3<Float>.zero; p[a] = s*h[a]; p[u] = pu; p[v] = pv; pts.append(p) }
                    var n = SIMD3<Float>.zero; n[a] = s
                    let f = face(pts,n); polygon(f.0, normal:f.1,color:color,kind:kind)
                }
            }
            for a in 0..<3 { for u in (a+1)..<3 {
                let v = 3-a-u
                for sa: Float in [-1,1] { for su: Float in [-1,1] {
                    var pts: [SIMD3<Float>] = []
                    for (side,t): (Int,Float) in [(0,-1),(1,-1),(1,1),(0,1)] {
                        var p = SIMD3<Float>.zero
                        p[a] = sa*(h[a] - (side == 0 ? 0 : b)); p[u] = su*(h[u] - (side == 0 ? b : 0)); p[v] = t*(h[v]-b); pts.append(p)
                    }
                    var n = SIMD3<Float>.zero; n[a] = sa; n[u] = su
                    let f = face(pts,n); polygon(f.0,normal:f.1,color:color,kind:kind)
                }}
            }}
            for sx: Float in [-1,1] { for sy: Float in [-1,1] { for sz: Float in [-1,1] {
                let s = SIMD3(sx,sy,sz)
                var pts: [SIMD3<Float>] = []
                for a in 0..<3 { var p = (h - SIMD3(repeating:b))*s; p[a] = h[a]*s[a]; pts.append(p) }
                let f = face(pts,s); polygon(f.0,normal:f.1,color:color,kind:kind)
            }}}
        }

        mutating func knob(_ c: SIMD3<Float>, radius: Float, height: Float) {
            let segments = 16
            for i in 0..<segments {
                let a = Float(i)*2*Float.pi/Float(segments)
                let b = Float(i+1)*2*Float.pi/Float(segments)
                let p = SIMD3<Float>(cos(a)*radius,0,sin(a)*radius)
                let q = SIMD3<Float>(cos(b)*radius,0,sin(b)*radius)
                let lift = SIMD3<Float>(0,height,0)
                polygon([c+p,c+q,c+q+lift,c+p+lift],normal:simd_normalize(p+q),color:alloy)
                polygon([c+lift,c+p+lift,c+q+lift],normal:iy,color:dark)
            }
            box(c+SIMD3(0,height+0.002,-radius*0.4),SIMD3(0.007,0.003,radius*0.7),edge,bevel:0.001)
        }

        mutating func beam(_ a: SIMD3<Float>, _ b: SIMD3<Float>, width: Float, depth: Float, color: SIMD3<Float>, kind: Float = 0) {
            let y = simd_normalize(b-a)
            let reference = abs(y.z) > 0.95 ? iy : iz
            let x = simd_normalize(simd_cross(y,reference)), z = simd_normalize(simd_cross(x,y))
            box((a+b)*0.5, SIMD3(width,simd_length(b-a),depth),color,bevel:min(width,depth)*0.2,kind:kind,x:x,y:y,z:z)
        }

        mutating func display(_ origin: SIMD3<Float>, width: Float, height: Float, variant: Float, x: SIMD3<Float>, y: SIMD3<Float>, n: SIMD3<Float>) {
            // The whole instrument sits proud of the dashboard module;
            // otherwise its outer rim shares a plane with the solid module.
            let c = origin + n * 0.025
            box(c - n*0.035,SIMD3(width+0.10,height+0.10,0.07),edge,bevel:0.025,x:x,y:y,z:n)
            box(c - n*0.004,SIMD3(width+0.045,height+0.045,0.018),dark,bevel:0.009,x:x,y:y,z:n)
            let halfX: SIMD3<Float> = x * (width * 0.5)
            let halfY: SIMD3<Float> = y * (height * 0.5)
            let glass = c + n * 0.014
            let positions: [SIMD3<Float>] = [glass-halfX-halfY, glass+halfX-halfY, glass+halfX+halfY, glass-halfX+halfY]
            let uv: [SIMD2<Float>] = [SIMD2(0,0),SIMD2(1,0),SIMD2(1,1),SIMD2(0,1)]
            for i in [0,1,2,0,2,3] { vertices.append(CabinVertex(position: SIMD4(positions[i],1),normal:SIMD4(n,0),color:SIMD4(cyan,1),detail:SIMD4(2,variant,uv[i].x,uv[i].y))) }
            // Recessed mounting screws on the outer bezel, with machined slots.
            for sx: Float in [-1, 1] { for sy: Float in [-1, 1] {
                let screw = c + x * (sx * (width/2 + 0.029)) + y * (sy * (height/2 + 0.028)) + n * 0.01
                box(screw, SIMD3(0.018, 0.018, 0.008), alloy, bevel: 0.007, x:x, y:y, z:n)
                box(screw+n*0.005, SIMD3(0.011, 0.003, 0.002), dark, bevel:0.0005, x:x, y:y, z:n)
            }}
            // Four independently modelled soft keys, separated by real recesses.
            for i in 0..<4 {
                let p = c + x*(Float(i)-1.5)*width/4 - y*(height/2+0.034) + n*0.013
                box(p,SIMD3(width/7,0.016,0.012),i == 0 ? amber : alloy,bevel:0.003,kind:i == 0 ? 1 : 0,x:x,y:y,z:n)
            }
        }

        mutating func build() {
            // Deep sill and chamfered dashboard, broken into modules rather than a flat HUD.
            box(SIMD3(0,-0.88,-1.9),SIMD3(4.8,0.48,0.72),dark,bevel:0.11)
            box(SIMD3(0,-0.61,-2.13),SIMD3(4.65,0.075,0.20),alloy,bevel:0.025)
            beam(SIMD3(-2.22,-0.555,-2.03),SIMD3(2.22,-0.555,-2.03),width:0.012,depth:0.016,color:cyan,kind:1)
            let slopeY = simd_normalize(SIMD3<Float>(0,0.84,-0.54))
            let slopeN = simd_normalize(SIMD3<Float>(0,0.54,0.84))
            for (i,px) in [Float(-1.53),-0.77,0,0.77,1.53].enumerated() {
                let raised: Float = i == 2 ? 0.06 : 0
                let c = SIMD3<Float>(px,-0.66+raised,-1.56)
                let screenHeight: Float = i == 2 ? 0.39 : 0.29
                box(c-slopeN*0.065,SIMD3(0.72,screenHeight+0.15,0.13),alloy,bevel:0.045,x:ix,y:slopeY,z:slopeN)
                display(c,width:0.58,height:screenHeight,variant:Float(i%3),x:ix,y:slopeY,n:slopeN)
            }
            // Secondary switch deck sits below the primary instrument bank.
            box(SIMD3(0,-1.01,-1.34),SIMD3(3.85,0.15,0.31),alloy,bevel:0.05)
            for row in 0..<2 { for col in 0..<27 {
                let px = (Float(col)-13)*0.126
                let p = SIMD3<Float>(px,-0.92,-1.43+Float(row)*0.115)
                if row == 0 && col % 3 == 1 {
                    knob(p,radius:0.025,height:0.035)
                } else {
                    box(p,SIMD3(0.07,0.016,0.044),col%7 == 0 ? amber : (col%3 == 0 ? cyan : dark),bevel:0.006,kind:col%3 == 0 ? 1 : 0)
                }
            }}
            // Canopy hoop: broad structural shoulders leave the centre of the windshield open.
            let front: [SIMD3<Float>] = [SIMD3(-2.38,-0.79,-2.30),SIMD3(-2.73,0.17,-2.5),SIMD3(-2.32,1.45,-2.58),SIMD3(-1.63,1.72,-2.6),SIMD3(1.63,1.72,-2.6),SIMD3(2.32,1.45,-2.58),SIMD3(2.73,0.17,-2.5),SIMD3(2.38,-0.79,-2.30)]
            for i in 0..<(front.count-1) {
                beam(front[i],front[i+1],width:0.19,depth:0.24,color:dark)
                beam(front[i]+SIMD3(0,0,0.14),front[i+1]+SIMD3(0,0,0.14),width:0.025,depth:0.035,color:edge)
            }
            for side: Float in [-1, 1] {
                let bottom = SIMD3<Float>(side*2.51,0.12,-2.33)
                let top = SIMD3<Float>(side*2.23,1.13,-2.42)
                for i in 0..<8 {
                    let t = Float(i) / 7
                    let p = bottom * (1-t) + top * t
                    box(p, SIMD3(0.065,0.027,0.018), i < 3 ? cyan : amber,
                        bevel:0.007, kind:1)
                }
            }
            // Roof rails continue behind the camera, visible during free look.
            for side: Float in [-1,1] {
                beam(SIMD3(side*1.72,1.55,-2.65),SIMD3(side*1.48,1.36,1.7),width:0.25,depth:0.20,color:dark)
                beam(SIMD3(side*2.4,-0.65,-2.15),SIMD3(side*2.0,-0.71,1.8),width:0.20,depth:0.27,color:alloy)
                box(SIMD3(side*2.24,-1.25,-0.1),SIMD3(0.20,1.0,3.9),dark,bevel:0.06)
                for z: Float in [-2.0,-0.7,0.7] {
                    box(SIMD3(side*1.49,1.285,z),SIMD3(0.18,0.03,0.25),alloy,bevel:0.018)
                    for i in 0..<4 { box(SIMD3(side*1.49,1.261,z+(Float(i)-1.5)*0.046),SIMD3(0.12,0.013,0.019),amber,bevel:0.004,kind:1) }
                }
                // Side console: horizontal instruments and a physical grab rail.
                box(SIMD3(side*1.77,-0.93,-0.13),SIMD3(0.68,0.37,1.72),alloy,bevel:0.08)
                display(SIMD3(side*1.77,-0.732,-0.50),width:0.42,height:0.5,variant:3,x:ix,y:SIMD3(0,0,-1),n:iy)
                beam(SIMD3(side*1.35,-0.69,0.12),SIMD3(side*1.35,-0.69,0.62),width:0.045,depth:0.045,color:edge)
                for i in 0..<5 { box(SIMD3(side*1.78 + (Float(i)-2)*0.092,-0.725,0.19),SIMD3(0.035,0.026,0.14),dark,bevel:0.009) }
            }
            box(SIMD3(0,1.58,0.0),SIMD3(3.2,0.15,4.0),dark,bevel:0.07)
            for z: Float in [-1.5,-0.3,0.9] { beam(SIMD3(-1.55,1.45,z),SIMD3(1.55,1.45,z),width:0.09,depth:0.13,color:alloy) }
            // Overhead switch panel, deliberately above the forward sight line.
            box(SIMD3(0,1.40,-1.10),SIMD3(0.86,0.14,0.73),alloy,bevel:0.04)
            for row in 0..<4 { for col in 0..<6 {
                box(SIMD3((Float(col)-2.5)*0.115,1.321,-1.1+(Float(row)-1.5)*0.13),SIMD3(0.043,0.018,0.055),(row+col)%4 == 0 ? amber : dark,bevel:0.005,kind:(row+col)%4 == 0 ? 1 : 0)
            }}
            // Centre pedestal comes towards the pilot, with dual thrust levers.
            box(SIMD3(0.62,-1.08,-0.33),SIMD3(0.46,0.59,1.55),dark,bevel:0.07)
            box(SIMD3(0.62,-0.77,-0.33),SIMD3(0.49,0.06,1.47),alloy,bevel:0.03)
            display(SIMD3(0.62,-0.733,-0.73),width:0.33,height:0.38,variant:1,x:ix,y:SIMD3(0,0,-1),n:iy)
            for dx: Float in [-0.105,0.105] {
                box(SIMD3(0.62+dx,-0.73,-0.12),SIMD3(0.032,0.012,0.38),dark,bevel:0.006)
                beam(SIMD3(0.62+dx,-0.71,-0.14),SIMD3(0.62+dx,-0.49,-0.23),width:0.035,depth:0.036,color:edge)
                box(SIMD3(0.62+dx,-0.48,-0.23),SIMD3(0.12,0.065,0.095),dark,bevel:0.024)
                box(SIMD3(0.62+dx,-0.446,-0.23),SIMD3(0.07,0.008,0.015),amber,bevel:0.002,kind:1)
            }
            // Deck, rear bulkhead, and recessed floor strips give a complete enclosed interior.
            box(SIMD3(0,-1.72,0),SIMD3(4.5,0.15,5.4),dark,bevel:0.05)
            for px: Float in [-1.15,0,1.15] { box(SIMD3(px,-1.635,0),SIMD3(0.018,0.009,4.7),alloy,bevel:0.002) }
            for px: Float in [-2.02,2.02] { box(SIMD3(px,-1.625,0),SIMD3(0.025,0.012,4.5),cyan,bevel:0.004,kind:1) }
            for side: Float in [-1, 1] {
                box(SIMD3(side*2.22,0.20,1.7),SIMD3(0.15,2.5,1.25),dark,bevel:0.04)
                box(SIMD3(side*2.125,-0.15,1.55),SIMD3(0.02,1.15,0.72),alloy,bevel:0.008)
            }
            box(SIMD3(0,-0.1,2.3),SIMD3(4.5,3.2,0.18),dark,bevel:0.06)
            box(SIMD3(0,-0.28,2.18),SIMD3(1.0,2.5,0.12),alloy,bevel:0.08)
            for px: Float in [-0.55,0.55] { box(SIMD3(px,-0.28,2.10),SIMD3(0.022,2.25,0.023),amber,bevel:0.004,kind:1) }
            for px: Float in [-0.18,1.22] { seat(px) }
        }

        mutating func seat(_ px: Float) {
            let fabric = SIMD3<Float>(0.035,0.055,0.065)
            box(SIMD3(px,-1.4,0.55),SIMD3(0.22,0.47,0.26),alloy,bevel:0.025)
            box(SIMD3(px,-1.10,0.51),SIMD3(0.67,0.16,0.69),dark,bevel:0.07)
            box(SIMD3(px,-0.99,0.46),SIMD3(0.54,0.13,0.59),fabric,bevel:0.055,kind:3)
            box(SIMD3(px,-0.56,0.87),SIMD3(0.67,1.0,0.20),dark,bevel:0.07)
            box(SIMD3(px,-0.57,0.737),SIMD3(0.49,0.83,0.12),fabric,bevel:0.05,kind:3)
            box(SIMD3(px,0.02,0.86),SIMD3(0.44,0.29,0.20),fabric,bevel:0.075,kind:3)
            for side: Float in [-1,1] {
                beam(SIMD3(px+side*0.33,-1.1,0.6),SIMD3(px+side*0.33,-0.70,0.51),width:0.05,depth:0.065,color:alloy)
                box(SIMD3(px+side*0.34,-0.68,0.40),SIMD3(0.12,0.09,0.46),fabric,bevel:0.036,kind:3)
            }
            for i in 0..<5 { box(SIMD3(px,-0.85+Float(i)*0.135,0.669),SIMD3(0.40,0.014,0.012),alloy,bevel:0.004) }
        }
    }
}
