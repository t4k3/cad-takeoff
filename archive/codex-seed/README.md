# Scaffold Codex precedente al coordinamento

Archivio storico, escluso dal progetto Xcode e dal package CADCore attivo.
Non è una seconda app da compilare insieme a FusionTakeoff.

Contiene la variante iniziale con Vector3/Triangle, validazione dei parametri,
controllo topologico della mesh, export STL binario, documento FileDocument
e viewport Metal. La base attiva usa Vec3/indices: eventuali recuperi richiedono
porting delle API, claim del task e test. Non copiare Mesh.swift o STLExporter.swift
direttamente nel core attivo.

Il test iniziale non è passato per collisione delle due implementazioni concorrenti.
Questo archivio NON costituisce prova di compilazione o di esecuzione del renderer Metal.

Origine: build/codex-seed-before-coordination.tar.gz, 25 settembre 2026.
Task T01, responsabile Codex.
