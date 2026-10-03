import Foundation

public enum ElectronicsFabrication {
    /// Pure, cancellable preparation. No file/network access, document mutation or history entry.
    /// Recompute on document identity/revision, profile or assembly-variant changes.
    public static func preview(document: ElectronicsDocument, expectedRevision: UInt64,
                               profile: FabricationProfile = .init(), variantID: UUID? = nil) throws -> FabricationPreview {
        try prepare(document:document,expectedRevision:expectedRevision,profile:profile,variantID:variantID).0
    }

    public static func export(document: ElectronicsDocument, expectedRevision: UInt64,
                              profile: FabricationProfile = .init(), variantID: UUID? = nil) throws -> FabricationPackage {
        let (preview, assembly) = try prepare(document:document,expectedRevision:expectedRevision,profile:profile,variantID:variantID)
        guard preview.canExport, let assembly else { throw ElectronicsFailure(preview.issues.filter { $0.severity == .error }) }
        return try FabricationWriter.package(document:document,preview:preview,assembly:assembly)
    }

    private static func prepare(document: ElectronicsDocument, expectedRevision: UInt64,
                                profile: FabricationProfile, variantID: UUID?) throws -> (FabricationPreview, AssemblyData?) {
        try Task.checkCancellation()
        guard document.revision == expectedRevision else {
            throw FabricationGeometry.issue("stale_revision","Il circuito è cambiato: ripetere la verifica prima di esportare.")
        }
        let nonnegative = [profile.solderMaskExpansion,profile.pasteInset]
        let positive = [profile.minimumMaskWeb,profile.minimumSilkscreenWidth,profile.silkscreenClearance,profile.minimumHoleSeparation]
        guard nonnegative.allSatisfy({ $0.isFinite && (0...5).contains($0) }),
              positive.allSatisfy({ $0.isFinite && (0.001...5).contains($0) }) else {
            throw FabricationGeometry.issue("fabrication_profile","Distanze di produzione non valide: usare valori finiti tra 0,001 e 5 mm; espansione maschera e riduzione pasta possono essere zero.")
        }
        let design = document.design
        if design.manufacturing != nil {
            throw FabricationGeometry.issue("manufacturing_export_unsupported", "La scheda contiene Gerber importati: l’export CAD e il DRC nativo non si applicano a questo pacchetto.")
        }
        let pcb = try ElectronicsPCB.snapshot(document)
        var issues = pcb.issues
        func add(_ code: String, _ message: String, _ ids: [UUID] = [], _ point: PCBPoint? = nil, warning: Bool = false) {
            var i = FabricationGeometry.issue(code,message,ids,point).issues[0]
            if warning { i.severity = .warning }; issues.append(i)
        }
        if pcb.layerCount != 2 { add("fabrication_layer_count","Questo export richiede due strati di rame. Il multistrato necessita di un profilo dedicato.") }
        if pcb.board.pads.isEmpty { add("fabrication_empty_board","La scheda non contiene piazzole: inserire e posizionare i componenti.") }
        for id in pcb.board.unplacedComponents { add("fabrication_unplaced","Componente senza posizione PCB, anche se non montato: posizionarlo o eliminarlo.",[id]) }
        // Routing warnings are useful during editing, but block manufacturing output.
        for i in issues.indices where ["pcb_unrouted","pcb_floating_copper","pcb_zone_empty"].contains(issues[i].code) { issues[i].severity = .error }
        let variant = variantID.flatMap { id in design.variants.first { $0.id == id } }
        if let variantID, variant == nil { add("unknown_variant","Variante di montaggio inesistente.",[variantID]) }
        let notFitted = Set((variant?.excludedComponents ?? []) + design.components.filter { $0.assembly == .doNotPopulate }.map(\.id))
        var electrical = ElectronicsValidation.electrical(design,excluding:notFitted)
        for i in electrical.indices where ["unconnected_pin","undriven_input","undriven_power","dangling_junction"].contains(electrical[i].code) { electrical[i].severity = .error }
        issues += electrical
        var assembly: AssemblyData?
        do {
            assembly = try ElectronicsAssembly.export(document,variantID:variantID)
            // These remain explicit warnings; assembly_data_only describes the old API, not this package.
            issues += assembly!.issues.filter { ["missing_3d_model","supplier_availability_unchecked","model_assets_unchecked"].contains($0.code) }
        } catch let failure as ElectronicsFailure { issues += failure.issues }

        var layers = Dictionary(uniqueKeysWithValues:FabricationLayerKind.twoLayer.map { ($0,[FabricationObject]()) })
        var drills: [FabricationDrill] = []
        for p in pcb.primitives {
            try Task.checkCancellation()
            let kind: FabricationObject.Kind
            switch p.item { case .track: kind = .stroke; case .zone: kind = .region; case .pad, .via: kind = .flash }
            for (number,layer) in [(0,FabricationLayerKind.topCopper),(pcb.layerCount-1,.bottomCopper)] where p.layers.contains(number) {
                layers[layer]!.append(FabricationGeometry.object(p,kind:kind))
            }
            if let drill = p.drillDiameter { drills.append(.init(subjectIDs:p.item.subjectIDs,position:p.center,diameter:drill)) }
            if case .via = p.item, !profile.tentVias {
                var opening = p; opening.radius += profile.solderMaskExpansion; opening.drillDiameter = nil
                for layer in [FabricationLayerKind.topMask,.bottomMask] { layers[layer]!.append(FabricationGeometry.object(opening)) }
            }
        }
        let placements = Dictionary(uniqueKeysWithValues:design.board.placements.map { ($0.componentID,$0) })
        for p in pcb.board.pads {
            try Task.checkCancellation()
            let flipped = placements[p.componentID]!.side == .bottom
            let source = p.sourceLayers
            func has(_ name: String, side: BoardSide) -> Bool {
                guard let source else { return p.drillDiameter == nil ? side == placements[p.componentID]!.side : name == "Mask" }
                let front = (side == .top) != flipped
                return source.contains("*."+name) || source.contains((front ? "F." : "B.")+name)
            }
            for side in [BoardSide.top,.bottom] {
                if has("Mask",side:side), let opening = FabricationGeometry.pad(p,margin:profile.solderMaskExpansion) {
                    layers[side == .top ? .topMask : .bottomMask]!.append(opening)
                }
                if p.drillDiameter == nil, !notFitted.contains(p.componentID), has("Paste",side:side) {
                    if let opening = FabricationGeometry.pad(p,margin:-profile.pasteInset) { layers[side == .top ? .topPaste : .bottomPaste]!.append(opening) }
                    else { add("fabrication_paste_size","La riduzione pasta annulla una piazzola: ridurla.",[p.componentID,p.padID],p.center) }
                }
            }
        }
        for component in design.components.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            guard let placement = placements[component.id] else { continue }
            let device = design.library.devices.first { $0.key == component.device }!
            let foot = design.library.footprints.first { $0.key == device.footprint }!
            if foot.properties?["qualification"] == "generic-unverified" {
                add("fabrication_generic_footprint","Impronta generica: verificarne misure e pinout sul datasheet prima della produzione.",[component.id,foot.key.id],placement.position,warning:true)
            }
            for g in (foot.graphics ?? []).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                guard ["F.SilkS","B.SilkS"].contains(g.layer) else {
                    if !["F.Fab","B.Fab","F.CrtYd","B.CrtYd"].contains(g.layer) {
                        add("fabrication_graphic_layer","Grafica sullo strato \(g.layer) non rappresentata dall’export: convertirla in oggetti supportati.",[component.id,g.id])
                    }
                    continue
                }
                let top = (g.layer == "F.SilkS") != (placement.side == .bottom)
                if !g.filled && g.strokeWidth+PCBGeometry.epsilon < profile.minimumSilkscreenWidth {
                    add("fabrication_silk_width","Serigrafia troppo sottile: aumentare lo spessore nella libreria.",[component.id,g.id],placement.position)
                }
                do { layers[top ? .topSilkscreen : .bottomSilkscreen]! += try FabricationGeometry.graphic(g,placement:placement) }
                catch let error as ElectronicsFailure { issues += error.issues }
            }
        }
        layers[.profile] = [.init(kind:.stroke,subjectIDs:[design.id],core:design.board.outline+[design.board.outline[0]],radius:0)]
        for (mask,silk) in [(FabricationLayerKind.topMask,FabricationLayerKind.topSilkscreen),(.bottomMask,.bottomSilkscreen)] {
            let openings = layers[mask]!, index = try PCBIndex(openings.map(\.copper))
            for i in openings.indices {
                try Task.checkCancellation()
                let a = openings[i].copper
                for j in index.query(PCBBox(a.core,margin:a.radius+profile.minimumMaskWeb)) where j > i {
                    let b = openings[j].copper
                    if PCBGeometry.gap(a,b)+PCBGeometry.epsilon < profile.minimumMaskWeb {
                        add("fabrication_mask_web","Aperture della maschera troppo vicine: ridurre l’espansione o distanziare le piazzole.",openings[i].subjectIDs+openings[j].subjectIDs,a.center)
                    }
                }
            }
            for object in layers[silk]! {
                try Task.checkCancellation()
                var touchesMask = false, outside = false
                for part in FabricationGeometry.parts(object) {
                    if part.core.contains(where: { !PCBGeometry.inside($0,design.board.outline) }) { outside = true }
                    let edge = PCBGeometry.edges(part.core).flatMap { a in PCBGeometry.edges(design.board.outline).map { PCBGeometry.segmentDistance(a.0,a.1,$0.0,$0.1) } }.min()!
                    if edge+PCBGeometry.epsilon < part.radius { outside = true }
                    if index.query(PCBBox(part.core,margin:part.radius+profile.silkscreenClearance+0.002)).contains(where: {
                        PCBGeometry.gap(part,openings[$0].copper)+PCBGeometry.epsilon < profile.silkscreenClearance+0.002
                    }) { touchesMask = true }
                }
                if touchesMask { add("fabrication_silk_mask","Serigrafia troppo vicina a un’apertura della maschera: correggere il disegno nella libreria.",object.subjectIDs,object.center) }
                if outside { add("fabrication_silk_edge","Serigrafia fuori dal contorno: spostarla all’interno della scheda.",object.subjectIDs,object.center) }
            }
        }
        let holePrimitives = drills.map { PCBCopperPrimitive(item:.via($0.subjectIDs.last!),netID:nil,layers:[0],core:[$0.position],radius:$0.diameter/2) }
        let holes = try PCBIndex(holePrimitives)
        if Set(drills.map { FabricationWriter.decimal($0.diameter) }).count > 99 {
            add("fabrication_drill_tools","Più di 99 diametri di foratura: uniformare i fori o usare un profilo dedicato.")
        }
        for i in drills.indices {
            try Task.checkCancellation()
            let a = holePrimitives[i]
            if drills[i].diameter < 0.000001 {
                add("fabrication_drill_resolution","Diametro del foro inferiore alla risoluzione del formato: aumentarlo.",drills[i].subjectIDs,drills[i].position)
            }
            for j in holes.query(PCBBox(a.core,margin:a.radius+profile.minimumHoleSeparation)) where j > i {
                if PCBGeometry.gap(a,holePrimitives[j])+PCBGeometry.epsilon < profile.minimumHoleSeparation {
                    add("fabrication_hole_separation","Forature troppo vicine per il profilo di produzione, anche sulla stessa rete.",drills[i].subjectIDs+drills[j].subjectIDs,drills[i].position)
                }
            }
        }
        // Output uses six integer/six fractional places; reject loss of geometry rather than clamp.
        for layer in FabricationLayerKind.twoLayer {
            for object in layers[layer]! {
                try Task.checkCancellation()
                if object.core.contains(where: { !validOutputPoint($0,origin:design.board.assemblyOrigin) }) ||
                    (object.radius != 0 && object.radius < 0.000001) {
                    add("fabrication_coordinate_range","Geometria fuori dal campo o dalla risoluzione dell’export: correggere dimensioni e origine.",object.subjectIDs,object.center)
                }
                if object.kind == .region {
                    let origin = design.board.assemblyOrigin
                    let quantized = object.core.map { PCBPoint((($0.x-origin.x)*1e6).rounded()/1e6,(($0.y-origin.y)*1e6).rounded()/1e6) }
                    if !ElectronicsGeometry.simplePolygon(quantized) {
                        add("fabrication_region_resolution","Un dettaglio del rame o della serigrafia degenera alla risoluzione dell’export: correggere il contorno.",object.subjectIDs,object.center)
                    }
                }
            }
        }
        add("fabrication_scope","Profilo generico a due strati: verificare datasheet, pin 1, orientamenti e processo del produttore. NPTH, asole, ritagli e multistrato non sono inclusi.",warning:true)
        if layers[.topSilkscreen]!.isEmpty && layers[.bottomSilkscreen]!.isEmpty {
            add("fabrication_no_silkscreen","Nessuna serigrafia definita: i file Legend saranno vuoti. Aggiungere i riferimenti e i segni di polarità necessari.",warning:true)
        }
        // Same error may come from both ERC and assembly validation; keep one navigable record.
        var seen = Set<String>()
        issues = issues.filter { seen.insert($0.code+"/"+$0.subject+"/"+($0.subjectIDs ?? []).map(\.uuidString).joined(separator:"/")).inserted }
        return (.init(designID:design.id,revision:document.revision,variantID:variantID,origin:design.board.assemblyOrigin,profile:profile,
                      layers:FabricationLayerKind.twoLayer.map { .init(kind:$0,objects:layers[$0]!) },drills:drills,issues:issues),assembly)
    }
    static func validOutputPoint(_ p: PCBPoint, origin: PCBPoint) -> Bool {
        [p.x-origin.x,p.y-origin.y].allSatisfy { $0.isFinite && abs($0) < 999999 }
    }
}
