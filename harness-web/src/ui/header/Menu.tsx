/**
 * The header's menu vocabulary — now a thin re-export of the shared kit.
 *
 * `Menu` / `MenuItem` / `MenuSection` used to be defined here, and the model
 * picker, the composer's completion popover, the sessions browser and the
 * context breakdown each had their own copy of the same ideas with none of the
 * same values. Everything floating in the pane is built from
 * `primitives/Popover.tsx` and `primitives/MenuList.tsx` now; this file keeps
 * the names the header already imports, so the header reads as header code
 * rather than as a tour of the primitives directory.
 */
export { Popover as Menu } from "../primitives/Popover";
export { MenuItem, MenuSection, MenuEmpty, MenuFooter, MenuKeys } from "../primitives/MenuList";
