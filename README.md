# SpellEfficiency

A World of Warcraft addon for the **Forever** client (Interface 16001). It compares the damage your known spells and abilities can do with your current spell power, crit, weapon and haste, then helps you press the right one.

## Features

- **Action bar glow**: glows the button of the spell to press now. Below a mana threshold it switches to the most mana-efficient spell.
- **Tooltips**: adds a line like `#1 damage - 13.7 DPS - 0.76 dmg/mana` to spell tooltips.
- **Next-spell icon**: shows Blizzard's suggested next spell, or a built-in priority rotation if there's no suggestion.
- **Comparison table** (`/se`):
  - Mana users: average damage per cast, DPS while casting, and damage per mana. It picks the highest-DPS filler, plus the most mana-efficient spell that still reaches 85% of the best DPS (adjustable).
  - Energy users: damage per energy, DPS when spamming, and builder ×5 + finisher cycles (rogue / cat druid).
- **Announcements**: a chat message when your best spell changes.

The numbers come from spell tooltips plus classic spell-power coefficient rules. Talents that the tooltip doesn't show, hit chance, resistances and armor are ignored. Treat it as a guide, not a simulator.

## Commands

| Command | Does |
|---|---|
| `/se` | Toggle the comparison table |
| `/se glow` | Toggle the action bar glow |
| `/se switch <0-100>` | Mana % below which the glow switches to the mana-efficient spell |
| `/se tips` | Toggle the tooltip line |
| `/se announce` | Toggle best-spell-changed messages |
| `/se next` | Toggle the next-spell icon |
| `/se lock` / `/se unlock` | Lock or unlock the next-spell icon |
| `/se scale <0.5-3>` | Next-spell icon size |
| `/se ranks` | Show lower spell ranks in the table |
| `/se comparable <50-100>` | % of the best DPS that the mana-efficient pick must reach |
| `/se reset` | Restore defaults |

## Install

Copy the `SpellEfficiency` folder into `World of Warcraft\_forever_\Interface\AddOns\` and restart the game or `/reload`.

## Libraries

Bundled under `Libs/`:

- [LibStub](https://www.wowace.com/projects/libstub): public domain
- [LibCustomGlow-1.0](https://github.com/Stanzilla/LibCustomGlow): MIT

## License

MIT. See [LICENSE](LICENSE).
