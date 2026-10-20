/// L'argent mis en mots, le meme sur le tableau de bord des finances et dans
/// son historique (demande du 18 octobre).
library;

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/historique.dart';
import '../../data/local/queries/finances_historique_queries.dart';
import '../../data/repositories/expense_repository.dart' show libelleRubrique;
import '../billing/charge_labels.dart' show paymentMethodLabel;
import '../billing/payment_dialog.dart' show iconePaiement;
import '../expenses/expenses_screen.dart' show iconeRubrique;

/// Le genre d'une ligne de l'historique des finances.
enum GenreArgent { encaissement, remboursement, arrhes, depense, caisse, facture }

/// Une ligne de l'historique, et son genre.
typedef LigneArgent = (EntreeHistorique, GenreArgent);

LigneArgent ligneDEncaissement(EncaissementHistorique e) {
  final p = AtriumPalette.current;
  return (
    EntreeHistorique(
      id: e.id,
      moment: e.moment ?? DateTime.now().toUtc(),
      icone: e.remboursement
          ? PhosphorIconsLight.arrowCounterClockwise
          : iconePaiement(e.moyen),
      couleur: e.remboursement ? p.error : p.success,
      titre: e.remboursement
          ? (e.annule != null ? 'Encaissement annulé' : 'Remboursement')
          : 'Encaissement',
      detail: [
        ?e.client,
        if (e.chambre != null) 'chambre ${e.chambre}',
        e.pointDeVente ?? 'Réception',
        paymentMethodLabel(e.moyen),
        if (e.reference != null && e.reference!.trim().isNotEmpty)
          'réf. ${e.reference!.trim()}',
        if (e.agent != null) 'par ${e.agent}',
      ].join(', '),
      montant: formatAmount(e.montant),
      negatif: e.remboursement,
    ),
    e.remboursement ? GenreArgent.remboursement : GenreArgent.encaissement,
  );
}

LigneArgent ligneDArrhes(ArrhesHistorique a) {
  final p = AtriumPalette.current;
  return (
    EntreeHistorique(
      id: 'arrhes|${a.id}',
      moment: a.moment,
      icone: PhosphorIconsLight.calendarCheck,
      couleur: p.success,
      titre: 'Arrhes reçues',
      detail: [?a.client, 'réservation ${a.reference}'].join(', '),
      montant: formatAmount(a.montant),
    ),
    GenreArgent.arrhes,
  );
}

LigneArgent ligneDeDepense(DepenseHistorique d) {
  final p = AtriumPalette.current;
  return (
    EntreeHistorique(
      id: 'depense|${d.id}',
      moment: d.moment ?? DateTime(d.jour.year, d.jour.month, d.jour.day, 12),
      icone: iconeRubrique(d.rubrique),
      couleur: d.annulee ? p.textSecondary : AtriumChartColors.negatif,
      titre: d.libelle,
      detail: [
        libelleRubrique(d.rubrique),
        ?d.fournisseur,
        if (d.moyen != null) paymentMethodLabel(d.moyen!),
        if (d.agent != null) 'par ${d.agent}',
        if (d.annulee && d.motifAnnulation != null)
          'annulée : ${d.motifAnnulation}',
      ].join(', '),
      montant: formatAmount(d.montant),
      // Une depense annulee reste, mais ne retranche plus rien.
      negatif: !d.annulee,
      etat: d.annulee ? 'Annulée' : null,
      couleurEtat: p.textSecondary,
    ),
    GenreArgent.depense,
  );
}

/// Une caisse en ses temps : ouverte, fermee (ou versee pour un comptoir),
/// recue par la reception.
List<LigneArgent> lignesDeCaisse(CaisseHistorique c) {
  final p = AtriumPalette.current;
  return [
    if (c.ouverteLe != null)
      (
        EntreeHistorique(
          id: '${c.id}|ouverte',
          moment: c.ouverteLe!,
          icone: PhosphorIconsLight.lockSimpleOpen,
          couleur: p.textSecondary,
          titre: c.pointDeVente == null
              ? 'Caisse de la réception ouverte'
              : 'Tiroir ouvert : ${c.pointDeVente}',
          detail: [
            if (c.agent != null) 'par ${c.agent}',
            'fond ${formatAmount(c.fond)}',
          ].join(', '),
          etat: c.fermeeLe == null ? 'Ouverte' : null,
          couleurEtat: p.accent,
        ),
        GenreArgent.caisse,
      ),
    if (c.fermeeLe != null)
      (
        EntreeHistorique(
          id: '${c.id}|fermee',
          moment: c.fermeeLe!,
          icone: PhosphorIconsLight.cashRegister,
          couleur: c.ecart == 0 ? p.accent : p.error,
          titre: c.pointDeVente == null
              ? 'Caisse de la réception fermée'
              : 'Recette versée : ${c.pointDeVente}',
          detail: [
            if (c.agent != null) 'par ${c.agent}',
            'attendu ${formatAmount(c.attendu)}',
            if (c.ecart != 0) 'écart ${_signe(c.ecart)}',
          ].join(', '),
          montant: c.compte == null ? null : formatAmount(c.compte!),
          etat: c.ecart != 0 ? 'Écart' : null,
          couleurEtat: p.error,
        ),
        GenreArgent.caisse,
      ),
    if (c.recuLe != null)
      (
        EntreeHistorique(
          id: '${c.id}|recue',
          moment: c.recuLe!,
          icone: PhosphorIconsLight.checkCircle,
          couleur: p.success,
          titre: 'Versement reçu : ${c.pointDeVente ?? 'caisse'}',
          detail: [
            if (c.recuPar != null) 'reçu par ${c.recuPar}',
            if (c.recu != null && c.compte != null && c.recu != c.compte)
              'écart ${_signe(c.recu! - c.compte!)}',
          ].join(', '),
          montant: c.recu == null ? null : formatAmount(c.recu!),
        ),
        GenreArgent.caisse,
      ),
  ];
}

List<LigneArgent> lignesDeFacture(FactureHistorique f) {
  final p = AtriumPalette.current;
  return [
    if (f.emiseLe != null)
      (
        EntreeHistorique(
          id: '${f.id}|emise',
          moment: f.emiseLe!,
          icone: PhosphorIconsLight.receipt,
          couleur: p.accent,
          titre: 'Facture ${f.numero} émise',
          detail: f.client,
          montant: formatAmount(f.total),
        ),
        GenreArgent.facture,
      ),
    if (f.annuleeLe != null)
      (
        EntreeHistorique(
          id: '${f.id}|annulee',
          moment: f.annuleeLe!,
          icone: PhosphorIconsLight.xCircle,
          couleur: p.error,
          titre: 'Facture ${f.numero} annulée',
          detail: [?f.client, ?f.motifAnnulation].join(', '),
          etat: 'Annulée',
          couleurEtat: p.error,
        ),
        GenreArgent.facture,
      ),
  ];
}

String _signe(int montant) =>
    '${montant > 0 ? '+' : '−'}${formatAmount(montant.abs())}';
