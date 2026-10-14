"""Les cinq sonneries des alertes, calculees : deux petites notes breves.

La direction voulait un son doux, qui ne fasse pas de bruit : chaque
sonnerie tient en moins d'une seconde, sans aigus au-dessus de 4 kHz, avec
sa crete a -11 dBFS. Le silence qui suit compte aussi : Android fait boucler
le son d'une alerte critique jusqu'a ce qu'on l'ouvre, et la boucle doit
respirer.

    python3 tool/sonneries.py            # depuis frontend/

Ecrit chaque fichier deux fois : dans `assets/sounds/` (l'application au
premier plan) et dans `android/app/src/main/res/raw/` (les canaux de
notification). Les noms suivent `Sonnerie.fichier` (alert_queries.dart).
"""
import wave
from pathlib import Path

import numpy as np

SR = 22050
DUREE = 1.6
rng = np.random.default_rng(7)

RACINE = Path(__file__).resolve().parent.parent
SORTIES = [RACINE / "assets" / "sounds", RACINE / "android" / "app" / "src" / "main" / "res" / "raw"]


def note(freq, partiels, duree=0.5, attaque=0.003):
    """partiels : (rapport, amplitude, constante de decroissance en s)."""
    t = np.arange(int(duree * SR)) / SR
    x = sum(a * np.sin(2 * np.pi * freq * r * t) * np.exp(-t / tau) for r, a, tau in partiels)
    n = int(attaque * SR)
    x[:n] *= 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, n))
    return x


def goutte(f0, duree=0.35):
    """Une note qui remonte d'un coup puis s'eteint : une goutte d'eau."""
    t = np.arange(int(duree * SR)) / SR
    f = f0 * (1 + 0.45 * (1 - np.exp(-t / 0.025)))
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.07)
    n = int(0.003 * SR)
    x[:n] *= 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, n))
    return x


def passe_bas(x, fc):
    a = np.exp(-2 * np.pi * fc / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def reverb(x, melange, duree=0.8, fc=3500):
    t = np.arange(int(duree * SR)) / SR
    ir = passe_bas(rng.standard_normal(len(t)) * np.exp(-t / (duree / 5)), fc)
    ir /= np.sqrt((ir ** 2).sum())
    taille = 1 << (len(x) + len(ir) - 2).bit_length()
    humide = np.fft.irfft(np.fft.rfft(x, taille) * np.fft.rfft(ir, taille), taille)[: len(x)]
    humide *= np.sqrt((x ** 2).sum() / max((humide ** 2).sum(), 1e-12))
    return (1 - melange) * x + melange * humide


def deux(premiere, seconde, ecart, melange=0.14, fc=4000):
    piste = np.zeros(int(DUREE * SR))
    for debut, son in ((0.0, premiere), (ecart, seconde * 0.85)):
        i = int(debut * SR)
        piste[i : i + len(son)] += son
    piste = reverb(passe_bas(piste, fc), melange)
    # La queue s'eteint avant le silence de fin, elle ne se coupe pas.
    fin = int(0.9 * SR)
    piste[fin - int(0.15 * SR) : fin] *= np.linspace(1, 0, int(0.15 * SR)) ** 2
    piste[fin:] = 0
    return piste * 10 ** (-11 / 20) / np.abs(piste).max()


BOIS = [(1, 1.0, 0.11), (3.93, 0.12, 0.025), (9.2, 0.02, 0.008)]
LEGER = [(1, 1.0, 0.07), (3.93, 0.08, 0.018)]
SOURD = [(1, 1.0, 0.06), (3.93, 0.15, 0.015)]

SONNERIES = {
    "sonnerie_meme_note": lambda: deux(note(659.25, BOIS), note(659.25, BOIS), 0.13),
    "sonnerie_qui_monte": lambda: deux(note(523.25, BOIS), note(783.99, BOIS), 0.13),
    "sonnerie_aigu_leger": lambda: deux(note(880.0, LEGER), note(1046.5, LEGER), 0.11),
    "sonnerie_bulles": lambda: deux(goutte(620), goutte(740), 0.12, melange=0.12, fc=3500),
    "sonnerie_bois_etouffe": lambda: deux(note(440.0, SOURD), note(523.25, SOURD), 0.15, melange=0.08),
}


def ecrire(chemin, x):
    with wave.open(str(chemin), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())


if __name__ == "__main__":
    for nom, calcul in SONNERIES.items():
        son = calcul()
        for dossier in SORTIES:
            ecrire(dossier / f"{nom}.wav", son)
        print(f"{nom}.wav  {len(son) / SR:.1f} s")
