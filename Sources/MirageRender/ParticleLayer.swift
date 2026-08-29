import Foundation
import Metal
import simd
import WEKit

/// The vertex `genericparticle.vert` expects. The shader reads
/// `in_ParticleRotation = vec3(a_TexCoordC2.xy, a_TexCoordVec4.z)`,
/// `in_ParticleSize = a_TexCoordVec4.w`, `in_ParticleVelocity = a_TexCoordVec4C1.xyz` and
/// `in_ParticleLifeTime = a_TexCoordVec4C1.w`, then expands the billboard itself.
/// Laid out with explicit scalars so the 80 byte stride is exact.
struct ParticleVertex {
    var px: Float = 0, py: Float = 0, pz: Float = 0, pw: Float = 0
    var uvx: Float = 0, uvy: Float = 0, rotZ: Float = 0, halfSize: Float = 0
    var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
    var vx: Float = 0, vy: Float = 0, vz: Float = 0, life: Float = 0
    var rotX: Float = 0, rotY: Float = 0
    var pad0: Float = 0, pad1: Float = 0
}

/// One live particle. Kept in a flat array and compacted in place each frame.
private struct Particle {
    var position: SIMD3<Float> = .zero
    var velocity: SIMD3<Float> = .zero
    var rotation: SIMD3<Float> = .zero
    var angularVelocity: SIMD3<Float> = .zero
    var color: SIMD3<Float> = SIMD3(repeating: 1)
    var alpha: Float = 1
    var size: Float = 20
    var lifetime: Float = 1
    var age: Float = 0
    var initColor: SIMD3<Float> = SIMD3(repeating: 1)
    var initAlpha: Float = 1
    var initSize: Float = 20
    var seed: UInt64 = 0
    var frameIndex: Int = 0
}

/// Simulates and draws one `particle` object of a scene.
///
/// Unlike image layers, particles are not a fixed pass chain: the geometry is rebuilt on
/// the CPU every frame and the vertex shader does the billboard expansion, which is why
/// this is the one place in the renderer that has to supply real matrices rather than the
/// identity the image path uses.
public final class ParticleLayer {
    public let object: WESceneObject
    let system: WEParticleSystem
    let instance: WEParticleSystem.InstanceOverride
    public private(set) var diagnostics: [String] = []

    var pass: CompiledPass?
    var texture: GPUTexture?
    /// Owned by the renderer: geometry is rebuilt every frame, so these are shared-storage
    /// buffers rather than inline bytes (a full pool exceeds Metal's 4 KiB inline limit).
    var vertexBuffer: MTLBuffer?
    var indexBuffer: MTLBuffer?
    /// Extra combos the shader needs, decided once the texture is known.
    var combos: [String: Int] = [:]

    private var particles: [Particle]
    private var liveCount = 0
    /// Where parent particles were born and died this frame, which is what a
    /// child system spawns from. Cleared at the start of every update.
    private(set) var birthEvents: [SIMD3<Float>] = []
    private(set) var deathEvents: [(position: SIMD3<Float>, velocity: SIMD3<Float>)] = []
    private var vertices: [ParticleVertex] = []
    private var indices: [UInt16] = []
    private var emitterTimers: [Float]
    private var emitterFired: [Bool]
    private var random = FastRandom(seed: 0x9E37_79B9_7F4A_7C15)
    private var spawnCounter: UInt64 = 0
    private var controlPoints: [SIMD3<Float>]
    private var elapsed: Float = 0
    private var hasStepped = false

    /// Scene space converted to the centred, y mirrored render space.
    private var transformedOrigin: SIMD3<Float> = .zero
    private var modelMatrix = matrix_identity_float4x4
    private var viewProjection = matrix_identity_float4x4

    /// Sprite sheet description, when the particle texture is animated.
    private var sheetColumns = 0
    private var sheetRows = 0
    private var sheetFrames = 0

    init(object: WESceneObject, system: WEParticleSystem) {
        self.object = object
        self.system = system
        self.instance = WEParticleSystem.InstanceOverride(json: object.instanceOverride)
        let capacity = max(1, min(20_000, Int((Float(system.maxCount) * instance.count).rounded())))
        self.particles = Array(repeating: Particle(), count: capacity)
        self.emitterTimers = Array(repeating: 0, count: system.emitters.count)
        self.emitterFired = Array(repeating: false, count: system.emitters.count)
        self.controlPoints = Array(repeating: .zero, count: 8)
        self.vertices = Array(repeating: ParticleVertex(), count: capacity * 4)
        self.indices = []
        indices.reserveCapacity(capacity * 6)
        for i in 0..<capacity {
            let base = UInt16(truncatingIfNeeded: i * 4)
            guard i * 4 + 3 <= Int(UInt16.max) else { break }
            indices.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 3, base])
        }
        for name in system.initializers.compactMap({ if case .unsupported(let n) = $0 { return n } else { return nil } })
        where !name.isEmpty {
            diagnostics.append("unsupported particle initializer: \(name)")
        }
        for name in system.operators.compactMap({ if case .unsupported(let n) = $0 { return n } else { return nil } })
        where !name.isEmpty {
            diagnostics.append("unsupported particle operator: \(name)")
        }
        if system.renderer.isRope {
            diagnostics.append("rope particle renderer falls back to sprites")
        }
    }

    func note(_ message: String) { diagnostics.append(message) }

    /// Only a system with children pays for event bookkeeping.
    var recordEvents = false
    /// Systems this one spawns, with the rule that triggers each.
    var children: [(spec: WEParticleSystem.Child, layer: ParticleLayer)] = []

    /// Spawns one particle at a position already in render space, as a child
    /// system does when its parent emits or dies.
    ///
    /// The initializer chain runs as usual, so the child keeps its own size,
    /// colour and lifetime, and then the parent's position replaces the
    /// emitter's and the inherited velocity is added on top.
    func spawnExternal(at position: SIMD3<Float>, inherit velocity: SIMD3<Float>, scale: Float) {
        guard liveCount < particles.count, let emitter = system.emitters.first else { return }
        var particle = spawn(from: emitter)
        particle.position = position
        particle.velocity += velocity
        if scale.isFinite, scale > 0 {
            particle.size *= scale
            particle.initSize *= scale
        }
        particles[liveCount] = particle
        liveCount += 1
    }

    /// Positions of the live parent particles, for a child that rides along.
    func livePositions(_ body: (SIMD3<Float>) -> Void) {
        for index in 0..<liveCount { body(particles[index].position) }
    }

    /// Removes every particle, used when a follow child is re-seated each frame.
    func removeAll() { liveCount = 0 }

    /// Called once the particle texture is resolved, so the sprite sheet grid is known.
    func configureSheet(with texture: GPUTexture?) {
        self.texture = texture
        guard let source = texture?.source, source.isAnimated, let first = source.frames.first else { return }
        let frameWidth = max(1, first.width), frameHeight = max(1, first.height)
        sheetColumns = max(1, Int((Float(source.width) / frameWidth).rounded()))
        sheetRows = max(1, Int((Float(source.height) / frameHeight).rounded()))
        sheetFrames = source.frames.count
    }

    public var isEmpty: Bool { liveCount == 0 }

    // MARK: Per frame

    /// Advances the simulation. `dt` is clamped by the caller.
    func beginEvents() {
        birthEvents.removeAll(keepingCapacity: true)
        deathEvents.removeAll(keepingCapacity: true)
    }

    func update(dt: Float, time: Float, sceneWidth: Float, sceneHeight: Float,
                projection: simd_float4x4, transform: ResolvedTransform, parallax: SIMD2<Float>,
                pointer: SIMD2<Float>, store: PropertyStore?) {
        elapsed = time
        // Scene space is y up with the origin bottom left; the renderer works in a centred
        // space mirrored in y, so the emitter origin and every y velocity flip with it.
        transformedOrigin = SIMD3(transform.origin.x - sceneWidth / 2,
                                  sceneHeight / 2 - transform.origin.y,
                                  transform.origin.z)
        var model = Mat.translation(transformedOrigin.x + parallax.x,
                                    transformedOrigin.y + parallax.y,
                                    transformedOrigin.z)
        let angles = object.angles.resolve(store).vec3 ?? .zero
        model = model * Mat.rotationZ(-angles.z)
        if angles.y != 0 || angles.x != 0 {
            model = model * Mat.rotation(SIMD3(-angles.x, angles.y, 0))
        }
        let scale = transform.scale
        model = model * Mat.scale(scale.x, scale.y, scale.z)
        modelMatrix = model
        viewProjection = projection

        updateControlPoints(pointer: pointer, sceneWidth: sceneWidth, sceneHeight: sceneHeight)

        // The first frame after load would otherwise emit a whole second of particles at once.
        guard hasStepped else { hasStepped = true; return }
        let step = min(max(dt, 0), 0.1)
        guard step > 0 else { return }

        emit(dt: step, time: time)
        advance(dt: step, time: time)
    }

    private func updateControlPoints(pointer: SIMD2<Float>, sceneWidth: Float, sceneHeight: Float) {
        for point in system.controlPoints {
            let index = ((point.id % 8) + 8) % 8
            if point.followsCursor {
                let cursor = SIMD3(pointer.x * sceneWidth - sceneWidth / 2,
                                   sceneHeight / 2 - pointer.y * sceneHeight, 0)
                controlPoints[index] = cursor + point.offset - transformedOrigin
            } else if point.isWorldSpace {
                controlPoints[index] = point.offset - transformedOrigin
            } else {
                controlPoints[index] = point.offset
            }
        }
    }

    // MARK: Emission

    private func emit(dt: Float, time: Float) {
        for (index, emitter) in system.emitters.enumerated() where index < emitterTimers.count {
            if emitter.delay > 0 && time < emitter.delay { continue }
            if emitter.duration > 0 && time > emitter.delay + emitter.duration { continue }

            var spawnCount = 0
            if emitter.instantaneous > 0 {
                if emitterFired[index] { continue }
                emitterFired[index] = true
                spawnCount = emitter.instantaneous
            } else {
                emitterTimers[index] += dt * emitter.rate * instance.rate * audioFactor(for: emitter)
                spawnCount = Int(emitterTimers[index])
                if spawnCount > 0 { emitterTimers[index] -= Float(spawnCount) }
                if emitter.oncePerFrame { spawnCount = min(spawnCount, 1) }
            }
            guard spawnCount > 0 else { continue }
            for _ in 0..<min(spawnCount, particles.count) {
                guard liveCount < particles.count else { break }
                particles[liveCount] = spawn(from: emitter)
                if recordEvents { birthEvents.append(particles[liveCount].position) }
                liveCount += 1
            }
        }
    }

    /// How much the audio spectrum scales this emitter's rate.
    ///
    /// Returns 1 for an emitter that does not listen, and also whenever the
    /// spectrum is entirely silent: a wallpaper whose visualiser is muted or
    /// whose audio permission was refused should keep emitting at its own rate
    /// rather than stopping dead.
    private func audioFactor(for emitter: WEParticleSystem.Emitter) -> Float {
        guard emitter.audioProcessingMode != 0, !audioSpectrum.isEmpty else { return 1 }
        let end = min(audioSpectrum.count, max(1, emitter.audioProcessingFrequencyEnd))
        var sum: Float = 0
        for i in 0..<end { sum += audioSpectrum[i] }
        let average = sum / Float(end)
        guard average > 0 else { return 1 }
        let low = emitter.audioProcessingBounds.x
        let high = emitter.audioProcessingBounds.y
        let span = high - low
        guard span.isFinite, abs(span) > 1e-6 else { return 1 }
        let normalised = min(1, max(0, (average - low) / span))
        let exponent = emitter.audioProcessingExponent.isFinite && emitter.audioProcessingExponent > 0
            ? emitter.audioProcessingExponent : 1
        let factor = pow(normalised, exponent)
        return factor.isFinite ? factor : 1
    }

    /// The spectrum this layer sees, set by the renderer each frame.
    var audioSpectrum: [Float] = []

    private func spawn(from emitter: WEParticleSystem.Emitter) -> Particle {
        var particle = Particle()
        spawnCounter &+= 1
        particle.seed = spawnCounter &* 0x9E37_79B9_7F4A_7C15
        let controlPoint = controlPoints[((emitter.controlPoint % 8) + 8) % 8]
        // The emitter's own origin is in scene space too, so its y flips like the object's.
        let origin = SIMD3(emitter.origin.x, -emitter.origin.y, emitter.origin.z) + controlPoint

        switch emitter.kind {
        case .box:
            var offset = SIMD3<Float>.zero
            for axis in 0..<3 {
                var distance = random.float(emitter.distanceMin[axis], emitter.distanceMax[axis])
                if random.float() < 0.5 { distance = -distance }
                offset[axis] = distance
            }
            offset *= SIMD3(emitter.directions.x, -emitter.directions.y, emitter.directions.z)
            particle.position = origin + offset
            if emitter.speedMax > 0 || emitter.speedMin != 0 {
                let length = simd_length(offset)
                if length > 0.0001 {
                    particle.velocity += (offset / length) * random.float(emitter.speedMin, emitter.speedMax)
                }
            }
        case .sphere:
            let radius = mix(emitter.distanceMin.x, emitter.distanceMax.x,
                             t: pow(random.float(), 1.0 / 3.0))
            var direction = SIMD3<Float>(
                emitter.directions.x > 0 ? random.gaussian(mean: 0, deviation: emitter.directions.x) : 0,
                emitter.directions.y > 0 ? random.gaussian(mean: 0, deviation: emitter.directions.y) : 0,
                emitter.directions.z > 0 ? random.gaussian(mean: 0, deviation: emitter.directions.z) : 0)
            let length = simd_length(direction)
            direction = length > 0.0001 ? direction / length : SIMD3(1, 0, 0)
            for axis in 0..<3 where emitter.sign[axis] != 0 {
                direction[axis] = emitter.sign[axis] > 0 ? abs(direction[axis]) : -abs(direction[axis])
            }
            let offset = direction * radius
            particle.position = origin + offset
            if emitter.speedMax > 0 || emitter.speedMin != 0 {
                particle.velocity += direction * random.float(emitter.speedMin, emitter.speedMax)
            }
        }

        for initializer in system.initializers { apply(initializer, to: &particle) }

        // instanceoverride scales the finished particle.
        particle.size *= instance.size
        particle.alpha *= instance.alpha
        particle.lifetime *= instance.lifetime
        particle.velocity *= instance.speed
        if let color = instance.color { particle.color = color }
        if let multiplier = instance.colorMultiplier { particle.color *= multiplier }

        particle.initColor = particle.color
        particle.initAlpha = particle.alpha
        particle.initSize = particle.size
        particle.lifetime = max(particle.lifetime, 0.0001)
        if case .randomframe = system.animationMode, sheetFrames > 0 {
            particle.frameIndex = Int(random.float() * Float(sheetFrames)) % max(1, sheetFrames)
        }
        return particle
    }

    private func apply(_ initializer: WEParticleSystem.Initializer, to particle: inout Particle) {
        switch initializer {
        case .lifetime(let lo, let hi):
            particle.lifetime = random.float(lo, hi)
        case .size(let lo, let hi, let exponent):
            let t = exponent == 1 ? random.float() : pow(random.float(), exponent)
            particle.size = mix(lo, hi, t: t)
        case .alpha(let lo, let hi):
            particle.alpha = random.float(lo, hi)
        case .color(let lo, let hi):
            // Wallpaper Engine draws one t and uses it for all three channels, which keeps
            // the ramp between the two colours instead of producing random hues.
            let t = random.float()
            particle.color = SIMD3(mix(lo.x, hi.x, t: t), mix(lo.y, hi.y, t: t), mix(lo.z, hi.z, t: t))
        case .velocity(let lo, let hi):
            let v = random.vector(lo, hi)
            particle.velocity += SIMD3(v.x, -v.y, v.z)
        case .rotation(let lo, let hi):
            particle.rotation += random.vector(lo, hi)
        case .angularVelocity(let lo, let hi, let exponent):
            var value = SIMD3<Float>.zero
            for axis in 0..<3 {
                let e = exponent[axis] == 0 ? 1 : exponent[axis]
                let t = e == 1 ? random.float() : pow(random.float(), e)
                value[axis] = mix(lo[axis], hi[axis], t: t)
            }
            particle.angularVelocity += value
        case .turbulentVelocity(let speedMin, let speedMax, let scale, let offset,
                                let forward, let right, _, let timeScale, let phaseMin, let phaseMax):
            let phase = random.float(phaseMin, phaseMax)
            let sample = SIMD3(particle.position.x * scale + phase + elapsed * timeScale,
                               particle.position.y * scale + offset,
                               particle.position.z * scale)
            let noise = Noise.curl(sample)
            let flippedForward = SIMD3(forward.x, -forward.y, forward.z)
            let flippedRight = SIMD3(right.x, -right.y, right.z)
            let direction = simd_normalize(noise.x * flippedRight + noise.y * flippedForward + SIMD3(0, 0, noise.z))
            if direction.x.isFinite {
                particle.velocity += direction * random.float(speedMin, speedMax)
            }
        case .unsupported:
            break
        }
    }

    // MARK: Simulation

    private func advance(dt: Float, time: Float) {
        var write = 0
        for read in 0..<liveCount {
            var particle = particles[read]
            particle.age += dt
            if particle.age >= particle.lifetime {
                if recordEvents { deathEvents.append((particle.position, particle.velocity)) }
                continue
            }

            // Operators are multiplicative onto the spawn values, so reset first.
            particle.color = particle.initColor
            particle.alpha = particle.initAlpha
            particle.size = particle.initSize

            let lifePos = min(max(particle.age / particle.lifetime, 0), 1)
            for (index, op) in system.operators.enumerated() {
                apply(op, index: index, to: &particle, dt: dt, lifePos: lifePos, time: time)
            }

            guard particle.position.x.isFinite, particle.position.y.isFinite,
                  particle.position.z.isFinite, particle.size.isFinite,
                  particle.size > 0, particle.size <= 10_000 else { continue }

            particles[write] = particle
            write += 1
        }
        liveCount = write
    }

    private func apply(_ op: WEParticleSystem.Operator, index: Int, to particle: inout Particle,
                       dt: Float, lifePos: Float, time: Float) {
        switch op {
        case .movement(let drag, let gravity):
            let flipped = SIMD3(gravity.x, -gravity.y, gravity.z)
            particle.velocity += (-2 * drag * particle.velocity + flipped) * dt
            particle.position += particle.velocity * dt
        case .angularMovement(let drag, let force):
            particle.rotation += particle.angularVelocity * dt
            particle.angularVelocity += force * dt
            particle.angularVelocity *= max(0, 1 - drag * dt)
        case .alphaFade(let fadeIn, let fadeOut):
            var factor: Float = 1
            if fadeIn > 0, lifePos < fadeIn { factor *= lifePos / fadeIn }
            if fadeOut > 0, lifePos > 1 - fadeOut { factor *= max(0, (1 - lifePos) / fadeOut) }
            particle.alpha *= factor
        case .alphaChange(let start, let end, let startTime, let endTime):
            particle.alpha *= ramp(lifePos, startTime, endTime, start, end)
        case .sizeChange(let start, let end, let startTime, let endTime):
            particle.size *= ramp(lifePos, startTime, endTime, start, end)
        case .colorChange(let start, let end, let startTime, let endTime):
            let t = normalized(lifePos, startTime, endTime)
            particle.color *= SIMD3(mix(start.x, end.x, t: t), mix(start.y, end.y, t: t), mix(start.z, end.z, t: t))
        case .oscillateAlpha(let fMin, let fMax, let sMin, let sMax, let pMin, let pMax):
            particle.alpha *= oscillate(particle, index, 0, fMin, fMax, sMin, sMax, pMin, pMax)
        case .oscillateSize(let fMin, let fMax, let sMin, let sMax, let pMin, let pMax):
            particle.size *= oscillate(particle, index, 1, fMin, fMax, sMin, sMax, pMin, pMax)
        case .oscillatePosition(let fMin, let fMax, let sMin, let sMax, let pMin, let pMax, let mask):
            for axis in 0..<3 where mask[axis] > 0.01 {
                let frequency = mix(fMin[axis], fMax[axis], t: hash(particle.seed, index, axis))
                let scale = mix(sMin[axis], sMax[axis], t: hash(particle.seed, index, axis + 3))
                let phase = mix(pMin[axis], pMax[axis], t: hash(particle.seed, index, axis + 6))
                particle.position[axis] += -scale * frequency * sin(frequency * particle.age + phase) * dt
            }
        case .turbulence(let scale, let speedMin, let speedMax, let timeScale, let mask, let pMin, let pMax):
            let phase = mix(pMin, pMax, t: hash(particle.seed, index, 0))
            let speed = mix(speedMin, speedMax, t: hash(particle.seed, index, 1))
            var sample = particle.position * scale * 2
            sample.x += phase + timeScale * time
            var direction = Noise.curl(sample)
            let length = simd_length(direction)
            guard length > 0.0001, length.isFinite else { break }
            direction = direction / length * speed
            for axis in 0..<3 where mask[axis] <= 0.01 { direction[axis] = 0 }
            particle.velocity += direction * dt
        case .vortex(let cp, let axis, let offset, _, let inner, let outer, let speedInner, let speedOuter):
            let centre = controlPoints[((cp % 8) + 8) % 8] + offset
            let radial = particle.position - centre
            let distance = simd_length(radial)
            guard distance > 0.0001 else { break }
            let normalizedAxis = simd_length(axis) > 0.0001 ? simd_normalize(axis) : SIMD3(0, 0, 1)
            let tangent = simd_cross(normalizedAxis, radial / distance)
            let t = outer > inner ? min(max((distance - inner) / (outer - inner), 0), 1) : 0
            particle.velocity += tangent * mix(speedInner, speedOuter, t: t) * dt
        case .controlPointAttract(let cp, let threshold, let scale):
            let centre = controlPoints[((cp % 8) + 8) % 8]
            let delta = centre - particle.position
            let distance = simd_length(delta)
            let radius = threshold / 2
            guard distance > 0.0001, distance < radius else { break }
            particle.velocity += (delta / distance) * scale * (1 - distance / radius) * dt
        case .unsupported:
            break
        }
    }

    // MARK: Geometry

    /// Fills the vertex buffer and returns the index count to draw.
    func buildGeometry() -> Int {
        guard liveCount > 0 else { return 0 }
        let corners: [(Float, Float)] = [(0, 1), (1, 1), (1, 0), (0, 0)]
        var vertexIndex = 0
        for i in 0..<liveCount {
            let particle = particles[i]
            let lifePos = min(max(particle.age / max(particle.lifetime, 0.0001), 0), 1)
            let life: Float
            switch system.animationMode {
            case .sequence: life = lifePos * system.sequenceMultiplier
            case .randomframe:
                life = sheetFrames > 0 ? (Float(particle.frameIndex) + 0.5) / Float(sheetFrames) : 0
            case .once: life = min(lifePos, 0.999)
            }
            for corner in corners {
                guard vertexIndex < vertices.count else { break }
                var vertex = ParticleVertex()
                vertex.px = particle.position.x
                vertex.py = particle.position.y
                vertex.pz = particle.position.z
                vertex.uvx = corner.0
                vertex.uvy = corner.1
                vertex.rotZ = particle.rotation.z
                vertex.halfSize = particle.size / 2
                vertex.r = particle.color.x
                vertex.g = particle.color.y
                vertex.b = particle.color.z
                vertex.a = min(max(particle.alpha, 0), 1)
                vertex.vx = particle.velocity.x
                vertex.vy = particle.velocity.y
                vertex.vz = particle.velocity.z
                vertex.life = life
                vertex.rotX = particle.rotation.x
                vertex.rotY = particle.rotation.y
                vertices[vertexIndex] = vertex
                vertexIndex += 1
            }
        }
        return min(liveCount, vertices.count / 4) * 6
    }

    var vertexByteCount: Int { vertices.count * MemoryLayout<ParticleVertex>.stride }
    var indexByteCount: Int { indices.count * MemoryLayout<UInt16>.stride }

    /// Copies the frame's geometry into the shared vertex buffer.
    func uploadVertices(into buffer: MTLBuffer, count: Int) {
        let bytes = min(count * 4 * MemoryLayout<ParticleVertex>.stride, buffer.length)
        guard bytes > 0 else { return }
        vertices.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: bytes)
        }
    }

    func uploadIndices(into buffer: MTLBuffer) {
        let bytes = min(indexByteCount, buffer.length)
        guard bytes > 0 else { return }
        indices.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: bytes)
        }
    }

    var liveParticleCount: Int { liveCount }

    // MARK: Uniforms

    /// Particle shaders build their own geometry, so unlike image passes they need the
    /// real transform, not an identity.
    func fillUniforms(_ bag: inout ShaderValueBag, brightness: Float) {
        let mvp = viewProjection * modelMatrix
        bag.set("g_ModelViewProjectionMatrix", mvp)
        bag.set("g_EffectModelViewProjectionMatrix", mvp)
        bag.set("g_ModelViewProjectionMatrixInverse", simd_inverse(mvp))
        bag.set("g_ModelMatrix", modelMatrix)
        bag.set("g_EffectModelMatrix", modelMatrix)
        bag.set("g_ModelMatrixInverse", simd_inverse(modelMatrix))
        bag.set("g_ViewProjectionMatrix", viewProjection)
        bag.set("g_EyePosition", SIMD3<Float>(0, 0, 1000))
        bag.set("g_OrientationUp", SIMD3<Float>(0, 1, 0))
        bag.set("g_OrientationRight", SIMD3<Float>(1, 0, 0))
        bag.set("g_OrientationForward", SIMD3<Float>(0, 0, 1))
        bag.set("g_ViewUp", SIMD3<Float>(0, 1, 0))
        bag.set("g_ViewRight", SIMD3<Float>(1, 0, 0))
        bag.set("g_ViewForward", SIMD3<Float>(0, 0, -1))
        bag.set("g_Brightness", brightness)
        bag.set("g_UserAlpha", instance.alpha)
        bag.set("g_Alpha", instance.alpha)

        var trailLength: Float = 0, trailMax: Float = 0
        if case .spriteTrail(let length, let maxLength, _) = system.renderer {
            trailLength = length
            trailMax = maxLength
        }
        bag.set("g_RenderVar0", SIMD4<Float>(trailLength, trailMax, 0, Float(max(0, particles.count - 1))))

        if sheetFrames > 0, sheetColumns > 0, sheetRows > 0, let source = texture?.source {
            let frameWidth = 1 / Float(sheetColumns)
            let frameHeight = 1 / Float(sheetRows)
            let ratio = (Float(source.height) * frameHeight) / max(1, Float(source.width) * frameWidth)
            bag.set("g_RenderVar1", SIMD4<Float>(frameWidth, frameHeight, Float(sheetFrames), ratio))
        } else if let source = texture?.source {
            bag.set("g_RenderVar1", SIMD4<Float>(0, 0, 0, Float(source.height) / max(1, Float(source.width))))
        } else {
            bag.set("g_RenderVar1", SIMD4<Float>(0, 0, 0, 1))
        }
    }

    /// Combos the particle shader needs, decided from the renderer and the texture.
    func shaderCombos() -> [String: Int] {
        var result: [String: Int] = ["THICKFORMAT": 1]
        if sheetFrames > 0 {
            result["SPRITESHEET"] = 1
            if !system.noFrameBlending { result["SPRITESHEETBLEND"] = 1 }
        }
        if system.renderer.isTrail { result["TRAILRENDERER"] = 1 }
        return result
    }

    // MARK: Helpers

    private func ramp(_ lifePos: Float, _ start: Float, _ end: Float, _ from: Float, _ to: Float) -> Float {
        mix(from, to, t: normalized(lifePos, start, end))
    }

    private func normalized(_ value: Float, _ start: Float, _ end: Float) -> Float {
        guard end > start else { return value >= end ? 1 : 0 }
        return min(max((value - start) / (end - start), 0), 1)
    }

    private func oscillate(_ particle: Particle, _ opIndex: Int, _ channel: Int,
                           _ fMin: Float, _ fMax: Float, _ sMin: Float, _ sMax: Float,
                           _ pMin: Float, _ pMax: Float) -> Float {
        let frequency = mix(fMin, fMax, t: hash(particle.seed, opIndex, channel))
        let scale = mix(sMin, sMax, t: hash(particle.seed, opIndex, channel + 16))
        _ = scale
        let phase = mix(pMin, pMax + 2 * .pi, t: hash(particle.seed, opIndex, channel + 32))
        let wave = (cos(frequency * particle.age + phase) + 1) * 0.5
        return mix(sMin, sMax, t: wave)
    }

    /// Deterministic per particle randomness, so oscillators do not need per particle storage.
    private func hash(_ seed: UInt64, _ a: Int, _ b: Int) -> Float {
        var x = seed &+ UInt64(bitPattern: Int64(a &* 0x9E3779B1)) &+ UInt64(bitPattern: Int64(b &* 0x85EBCA6B))
        x ^= x >> 33
        x = x &* 0xFF51AFD7ED558CCD
        x ^= x >> 33
        return Float(x >> 40) / Float(1 << 24)
    }
}

private func mix(_ a: Float, _ b: Float, t: Float) -> Float { a + (b - a) * min(max(t, 0), 1) }
