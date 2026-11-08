import Foundation

/// Elementos orbitales de un satélite en formato TLE (dos líneas de NORAD/CelesTrak).
struct TLE: Equatable, Identifiable {
    var id: String { name + line1.prefix(7) }
    let name: String
    let line1: String
    let line2: String
    let epochJD: Double
    let bstar: Double
    let incl: Double        // rad
    let node: Double        // rad
    let ecc: Double
    let argp: Double        // rad
    let mo: Double          // rad
    let noKozai: Double     // rad/min

    /// Lee un TLE. Comprueba el formato y la suma de control de cada línea.
    static func parse(name: String, line1 l1: String, line2 l2: String) -> TLE? {
        let a = Array(l1), b = Array(l2)
        guard a.count >= 69, b.count >= 69, a[0] == "1", b[0] == "2", checksumOK(a), checksumOK(b) else { return nil }
        func f(_ c: [Character], _ s: Int, _ e: Int) -> String { String(c[s..<e]).trimmingCharacters(in: .whitespaces) }
        func d(_ c: [Character], _ s: Int, _ e: Int) -> Double? { Double(f(c, s, e)) }
        // Notación TLE «12345-3» = 0.12345e-3.
        func exp(_ s: String) -> Double? {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2 else { return 0 }
            var mant = String(t.dropLast(2)), e = String(t.suffix(2))
            if !mant.hasPrefix("-") && !mant.hasPrefix("+") { mant = "+" + mant }
            let sign: Double = mant.hasPrefix("-") ? -1 : 1
            mant.removeFirst()
            guard let m = Double("0." + mant), let ex = Double(e) else { return nil }
            return sign * m * pow(10, ex)
        }
        guard let yy = Int(f(a, 18, 20)), let doy = d(a, 20, 32), let bs = exp(f(a, 53, 61)),
              let inc = d(b, 8, 16), let raan = d(b, 17, 25), let eccS = Double("0." + f(b, 26, 33)),
              let ap = d(b, 34, 42), let ma = d(b, 43, 51), let nrev = d(b, 52, 63), nrev > 0 else { return nil }
        let year = yy < 57 ? 2000 + yy : 1900 + yy
        let jan1 = Comets.julianDay(year: year, month: 1, day: 1)
        let r = Double.pi / 180
        return TLE(name: name.trimmingCharacters(in: .whitespaces), line1: l1, line2: l2, epochJD: jan1 + doy - 1, bstar: bs,
                   incl: inc * r, node: raan * r, ecc: eccS, argp: ap * r, mo: ma * r, noKozai: nrev * 2 * .pi / 1440)
    }

    static func checksumOK(_ c: [Character]) -> Bool {
        var sum = 0
        for ch in c[0..<68] { if let v = ch.wholeNumberValue { sum += v } else if ch == "-" { sum += 1 } }
        return c[68].wholeNumberValue == sum % 10
    }

    /// Lista de tres líneas (nombre + TLE) como la que da CelesTrak.
    static func parseList(_ text: String, max: Int = 2000) -> [TLE] {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        var out: [TLE] = []
        var i = 0
        while i + 2 < lines.count && out.count < max {
            if !lines[i].hasPrefix("1 ") && lines[i + 1].hasPrefix("1 ") && lines[i + 2].hasPrefix("2 "),
               let t = parse(name: lines[i], line1: lines[i + 1], line2: lines[i + 2]) {
                out.append(t); i += 3
            } else { i += 1 }
        }
        return out
    }
}

/// SGP4 para órbitas cercanas a la Tierra (periodo < 225 min: la ISS y los satélites brillantes),
/// constantes WGS-72, según el informe Spacetrack nº 3 revisado por Vallado et al. (2006).
/// Devuelve posición (km) y velocidad (km/s) en el sistema TEME.
struct SGP4 {
    static let re = 6378.135, mu = 398600.8
    static let xke = 60.0 / sqrt(re * re * re / mu)
    static let j2 = 0.001082616, j3 = -0.00000253881, j4 = -0.00000165597
    static let j3oj2 = j3 / j2

    let tle: TLE
    private var isimp = false
    private var aycof = 0.0, con41 = 0.0, cc1 = 0.0, cc4 = 0.0, cc5 = 0.0, d2 = 0.0, d3 = 0.0, d4 = 0.0
    private var delmo = 0.0, eta = 0.0, argpdot = 0.0, omgcof = 0.0, sinmao = 0.0, t2cof = 0.0, t3cof = 0.0
    private var t4cof = 0.0, t5cof = 0.0, x1mth2 = 0.0, x7thm1 = 0.0, mdot = 0.0, nodedot = 0.0, xlcof = 0.0
    private var xmcof = 0.0, nodecf = 0.0, noUnkozai = 0.0

    /// nil si la órbita es de espacio profundo (periodo ≥ 225 min), que este modelo no cubre.
    init?(_ tle: TLE) {
        self.tle = tle
        let e = tle.ecc, i = tle.incl
        let cosio = cos(i), cosio2 = cosio * cosio, eccsq = e * e, omeosq = 1 - eccsq, rteosq = sqrt(omeosq)
        let ak = pow(Self.xke / tle.noKozai, 2.0 / 3)
        let d1 = 0.75 * Self.j2 * (3 * cosio2 - 1) / (rteosq * omeosq)
        var del = d1 / (ak * ak)
        let adel = ak * (1 - del * del - del * (1.0 / 3 + 134 * del * del / 81))
        del = d1 / (adel * adel)
        noUnkozai = tle.noKozai / (1 + del)
        guard 2 * .pi / noUnkozai < 225 else { return nil }
        let ao = pow(Self.xke / noUnkozai, 2.0 / 3)
        let sinio = sin(i), po = ao * omeosq, con42 = 1 - 5 * cosio2
        con41 = -con42 - cosio2 - cosio2
        let posq = po * po, rp = ao * (1 - e)
        isimp = rp < 220 / Self.re + 1
        var sfour = 78 / Self.re + 1
        var qzms24 = pow((120 - 78) / Self.re, 4)
        let perige = (rp - 1) * Self.re
        if perige < 156 {
            sfour = perige - 78
            if perige < 98 { sfour = 20 }
            qzms24 = pow((120 - sfour) / Self.re, 4)
            sfour = sfour / Self.re + 1
        }
        let pinvsq = 1 / posq, tsi = 1 / (ao - sfour)
        eta = ao * e * tsi
        let etasq = eta * eta, eeta = e * eta, psisq = abs(1 - etasq)
        let coef = qzms24 * pow(tsi, 4), coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * noUnkozai * (ao * (1 + 1.5 * etasq + eeta * (4 + etasq))
                  + 0.375 * Self.j2 * tsi / psisq * con41 * (8 + 3 * etasq * (8 + etasq)))
        cc1 = tle.bstar * cc2
        let cc3 = e > 1e-4 ? -2 * coef * tsi * Self.j3oj2 * noUnkozai * sinio / e : 0
        x1mth2 = 1 - cosio2
        cc4 = 2 * noUnkozai * coef1 * ao * omeosq * (eta * (2 + 0.5 * etasq) + e * (0.5 + 2 * etasq)
              - Self.j2 * tsi / (ao * psisq) * (-3 * con41 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta))
              + 0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * cos(2 * tle.argp)))
        cc5 = 2 * coef1 * ao * omeosq * (1 + 2.75 * (etasq + eeta) + eeta * etasq)
        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * Self.j2 * pinvsq * noUnkozai, temp2 = 0.5 * temp1 * Self.j2 * pinvsq
        let temp3 = -0.46875 * Self.j4 * pinvsq * pinvsq * noUnkozai
        mdot = noUnkozai + 0.5 * temp1 * rteosq * con41 + 0.0625 * temp2 * rteosq * (13 - 78 * cosio2 + 137 * cosio4)
        argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7 - 114 * cosio2 + 395 * cosio4) + temp3 * (3 - 36 * cosio2 + 49 * cosio4)
        let xhdot1 = -temp1 * cosio
        nodedot = xhdot1 + (0.5 * temp2 * (4 - 19 * cosio2) + 2 * temp3 * (3 - 7 * cosio2)) * cosio
        omgcof = tle.bstar * cc3 * cos(tle.argp)
        xmcof = e > 1e-4 ? -2.0 / 3 * coef * tle.bstar / eeta : 0
        nodecf = 3.5 * omeosq * xhdot1 * cc1
        t2cof = 1.5 * cc1
        xlcof = abs(cosio + 1) > 1.5e-12 ? -0.25 * Self.j3oj2 * sinio * (3 + 5 * cosio) / (1 + cosio)
                                          : -0.25 * Self.j3oj2 * sinio * (3 + 5 * cosio) / 1.5e-12
        aycof = -0.5 * Self.j3oj2 * sinio
        delmo = pow(1 + eta * cos(tle.mo), 3)
        sinmao = sin(tle.mo)
        x7thm1 = 7 * cosio2 - 1
        if !isimp {
            let cc1sq = cc1 * cc1
            d2 = 4 * ao * tsi * cc1sq
            let temp = d2 * tsi * cc1 / 3
            d3 = (17 * ao + sfour) * temp
            d4 = 0.5 * temp * ao * tsi * (221 * ao + 31 * sfour) * cc1
            t3cof = d2 + 2 * cc1sq
            t4cof = 0.25 * (3 * d3 + cc1 * (12 * d2 + 10 * cc1sq))
            t5cof = 0.2 * (3 * d4 + 12 * cc1 * d3 + 6 * d2 * d2 + 15 * cc1sq * (2 * d2 + cc1sq))
        }
    }

    /// Posición (km) y velocidad (km/s) TEME a `t` minutos de la época. nil si la órbita ya ha decaído.
    func propagate(minutes t: Double) -> (r: SIMD3<Double>, v: SIMD3<Double>)? {
        let twopi = 2 * Double.pi
        let xmdf = tle.mo + mdot * t, argpdf = tle.argp + argpdot * t, nodedf = tle.node + nodedot * t
        var argpm = argpdf, mm = xmdf
        let t2 = t * t
        var nodem = nodedf + nodecf * t2
        var tempa = 1 - cc1 * t, tempe = tle.bstar * cc4 * t, templ = t2cof * t2
        if !isimp {
            let delomg = omgcof * t
            let delm = xmcof * (pow(1 + eta * cos(xmdf), 3) - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * t, t4 = t3 * t
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe = tempe + tle.bstar * cc5 * (sin(mm) - sinmao)
            templ = templ + t3cof * t3 + t4 * (t4cof + t * t5cof)
        }
        var nm = noUnkozai
        var em = tle.ecc
        let inclm = tle.incl
        let am = pow(Self.xke / nm, 2.0 / 3) * tempa * tempa
        nm = Self.xke / pow(am, 1.5)
        em = em - tempe
        guard em < 1, em > -0.001, am > 0.95 else { return nil }
        if em < 1e-6 { em = 1e-6 }
        mm = mm + noUnkozai * templ
        var xlm = mm + argpm + nodem
        nodem = nodem.truncatingRemainder(dividingBy: twopi)
        argpm = argpm.truncatingRemainder(dividingBy: twopi)
        xlm = xlm.truncatingRemainder(dividingBy: twopi)
        mm = (xlm - argpm - nodem).truncatingRemainder(dividingBy: twopi)
        let sinip = sin(inclm), cosip = cos(inclm)
        let axnl = em * cos(argpm)
        var temp = 1 / (am * (1 - em * em))
        let aynl = em * sin(argpm) + temp * aycof
        let xl = mm + argpm + nodem + temp * xlcof * axnl
        let u = (xl - nodem).truncatingRemainder(dividingBy: twopi)
        var eo1 = u, tem5 = 9999.9, ktr = 1
        var sineo1 = 0.0, coseo1 = 0.0
        while abs(tem5) >= 1e-12 && ktr <= 10 {
            sineo1 = sin(eo1); coseo1 = cos(eo1)
            tem5 = 1 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0 ? 0.95 : -0.95 }
            eo1 += tem5
            ktr += 1
        }
        let ecose = axnl * coseo1 + aynl * sineo1, esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl, pl = am * (1 - el2)
        guard pl > 0 else { return nil }
        let rl = am * (1 - ecose), rdotl = sqrt(am) * esine / rl, rvdotl = sqrt(pl) / rl
        let betal = sqrt(1 - el2)
        temp = esine / (1 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * temp), cosu = am / rl * (coseo1 - axnl + aynl * temp)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu, cos2u = 1 - 2 * sinu * sinu
        temp = 1 / pl
        let temp1 = 0.5 * Self.j2 * temp, temp2 = temp1 * temp
        let mrt = rl * (1 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
        su = su - 0.25 * temp2 * x7thm1 * sin2u
        let xnode = nodem + 1.5 * temp2 * cosip * sin2u
        let xinc = inclm + 1.5 * temp2 * cosip * sinip * cos2u
        let mvt = rdotl - nm * temp1 * x1mth2 * sin2u / Self.xke
        let rvdot = rvdotl + nm * temp1 * (x1mth2 * cos2u + 1.5 * con41) / Self.xke
        let sinsu = sin(su), cossu = cos(su), snod = sin(xnode), cnod = cos(xnode), sini = sin(xinc), cosi = cos(xinc)
        let xmx = -snod * cosi, xmy = cnod * cosi
        let uu = SIMD3(xmx * sinsu + cnod * cossu, xmy * sinsu + snod * cossu, sini * sinsu)
        let vv = SIMD3(xmx * cossu - cnod * sinsu, xmy * cossu - snod * sinsu, sini * cossu)
        guard mrt >= 1 else { return nil }            // por debajo de la superficie: ha decaído
        let vk = Self.re * Self.xke / 60
        return (mrt * uu * Self.re, (mvt * uu + rvdot * vv) * vk)
    }

    func position(at date: Date) -> SIMD3<Double>? {
        propagate(minutes: (Astro.julianDay(date) - tle.epochJD) * 1440)?.r
    }
}

/// Paso de un satélite visible desde el lugar de observación.
struct SatellitePass: Identifiable, Equatable {
    var id: String { "\(name)|\(rise.timeIntervalSince1970)" }
    let name: String
    let rise: Date
    let peak: Date
    let set: Date
    let maxAltitude: Double
    let riseAzimuth: Double
    let setAzimuth: Double
    /// Iluminado por el Sol en el punto más alto (si no, no se ve).
    let sunlit: Bool
}

enum Satellites {
    /// Tiempo sidéreo de Greenwich (rad) para un día juliano UT.
    static func gmst(_ jd: Double) -> Double {
        let t = (jd - 2451545.0) / 36525
        var s = 67310.54841 + (876600 * 3600 + 8640184.812866) * t + 0.093104 * t * t - 6.2e-6 * t * t * t
        s = s.truncatingRemainder(dividingBy: 86400)
        if s < 0 { s += 86400 }
        return s / 240 * .pi / 180
    }

    /// Observador en coordenadas terrestres (km, WGS-84).
    static func observer(lat: Double, lon: Double, heightKm: Double = 0.6) -> SIMD3<Double> {
        let a = 6378.137, f = 1 / 298.257223563, e2 = f * (2 - f)
        let p = lat * .pi / 180, l = lon * .pi / 180
        let n = a / sqrt(1 - e2 * sin(p) * sin(p))
        return SIMD3((n + heightKm) * cos(p) * cos(l), (n + heightKm) * cos(p) * sin(l), (n * (1 - e2) + heightKm) * sin(p))
    }

    /// Altura y acimut (°) de un satélite (posición TEME) para el observador.
    static func altAz(teme r: SIMD3<Double>, date: Date, lat: Double, lon: Double) -> (alt: Double, az: Double, range: Double) {
        let g = gmst(Astro.julianDay(date))
        let ecef = SIMD3(r.x * cos(g) + r.y * sin(g), -r.x * sin(g) + r.y * cos(g), r.z)
        let o = observer(lat: lat, lon: lon)
        let d = ecef - o
        let p = lat * .pi / 180, l = lon * .pi / 180
        let s = sin(p) * cos(l) * d.x + sin(p) * sin(l) * d.y - cos(p) * d.z
        let e = -sin(l) * d.x + cos(l) * d.y
        let z = cos(p) * cos(l) * d.x + cos(p) * sin(l) * d.y + sin(p) * d.z
        let range = (d * d).sum().squareRoot()
        var az = atan2(e, -s) * 180 / .pi
        if az < 0 { az += 360 }
        return (asin(z / range) * 180 / .pi, az, range)
    }

    /// ¿Le da el Sol al satélite? (sombra cilíndrica de la Tierra)
    static func sunlit(teme r: SIMD3<Double>, date: Date) -> Bool {
        let s = Astro.sun(date)
        let ra = s.ra * 15 * .pi / 180, dec = s.dec * .pi / 180
        let u = SIMD3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
        let along = (r * u).sum()
        if along > 0 { return true }
        let perp = r - along * u
        return (perp * perp).sum().squareRoot() > 6378.137
    }

    /// Pasos visibles (observador a oscuras, Sol bajo −6°) en los próximos `days` días, por encima de `minAltitude`.
    static func passes(_ tle: TLE, from start: Date = Date(), days: Double = 5, lat: Double, lon: Double,
                       minAltitude: Double = 10, onlyVisible: Bool = true) -> [SatellitePass] {
        guard let sgp = SGP4(tle) else { return [] }
        var out: [SatellitePass] = []
        var t = start
        let end = start.addingTimeInterval(days * 86400)
        var inPass = false
        var rise = start, peak = start, maxAlt = -90.0, riseAz = 0.0, peakSunlit = false
        var lastAz = 0.0
        while t < end {
            // Fuera de la noche se avanza deprisa.
            if onlyVisible && !inPass && Astro.sunAltitude(t, lat: lat, lon: lon) > -6 { t = t.addingTimeInterval(300); continue }
            guard let r = sgp.position(at: t) else { break }
            let aa = altAz(teme: r, date: t, lat: lat, lon: lon)
            if aa.alt >= minAltitude {
                if !inPass { inPass = true; rise = t; riseAz = aa.az; maxAlt = -90 }
                if aa.alt > maxAlt { maxAlt = aa.alt; peak = t; peakSunlit = sunlit(teme: r, date: t) }
                lastAz = aa.az
            } else if inPass {
                inPass = false
                if peakSunlit || !onlyVisible {
                    out.append(SatellitePass(name: tle.name, rise: rise, peak: peak, set: t, maxAltitude: maxAlt,
                                             riseAzimuth: riseAz, setAzimuth: lastAz, sunlit: peakSunlit))
                }
            }
            // Pasos de 20 s (4 s durante el paso, para afinar la altura máxima); lejos del horizonte, de 60 s.
            t = t.addingTimeInterval(inPass ? 4 : (aa.alt < -20 ? 60 : 20))
        }
        return out
    }

    /// Separación mínima (°) entre un satélite y un punto del cielo durante un intervalo, y cuándo.
    static func closestApproach(_ tle: TLE, raHours: Double, decDeg: Double, from: Date, to: Date,
                                lat: Double, lon: Double) -> (sep: Double, at: Date)? {
        guard let sgp = SGP4(tle) else { return nil }
        let target = Astro.precessFromJ2000(raHours: raHours, decDeg: decDeg, to: from)
        let tAA = { (d: Date) in Astro.altAz(raHours: target.ra, decDeg: target.dec, date: d, lat: lat, lon: lon) }
        var best: (Double, Date)?
        var t = from
        while t <= to {
            // Paso adaptable: un satélite bajo cruza hasta 1° por segundo, así que cerca del objetivo se afina.
            var step: TimeInterval = 30
            guard let r = sgp.position(at: t) else { break }
            let s = altAz(teme: r, date: t, lat: lat, lon: lon)
            if s.alt < -30 { step = 120 } else if s.alt > -5 {
                let o = tAA(t)
                let sep = angularDistance(alt1: s.alt, az1: s.az, alt2: o.alt, az2: o.az)
                if s.alt > 0, best == nil || sep < best!.0 { best = (sep, t) }
                step = sep < 10 ? 0.25 : (sep < 40 ? 2 : 10)
            }
            t = t.addingTimeInterval(step)
        }
        return best.map { (sep: $0.0, at: $0.1) }
    }

    static func angularDistance(alt1: Double, az1: Double, alt2: Double, az2: Double) -> Double {
        let r = Double.pi / 180
        let c = sin(alt1 * r) * sin(alt2 * r) + cos(alt1 * r) * cos(alt2 * r) * cos((az1 - az2) * r)
        return acos(max(-1, min(1, c))) / r
    }
}
