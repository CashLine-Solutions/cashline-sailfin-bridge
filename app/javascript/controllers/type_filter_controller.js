import { Controller } from "@hotwired/stimulus"

// Client-side filter for the fields table. Toggle a data_type chip to
// hide rows whose data-field-type doesn't match. Click the same chip
// again (or "All") to clear the filter.
//
// Markup contract:
//   <div data-controller="type-filter"
//        data-type-filter-active-class-value="<active css string>"
//        data-type-filter-inactive-class-value="<inactive css string>">
//     <button data-type-filter-target="chip"
//             data-action="click->type-filter#filter"
//             data-type-value="all">All</button>
//     <button data-type-filter-target="chip"
//             data-action="click->type-filter#filter"
//             data-type-value="string">string</button>
//     ...
//     <table>
//       <tr data-field-type="string">...</tr>
//       <tr data-field-type="string" data-detail-for="...">...</tr>  // detail row
//     </table>
//   </div>
//
// Uses Tailwind's `hidden` class to toggle row visibility, which preserves
// any existing inline state (expanded detail panels survive filtering).
//
// Class toggling on chips uses classList.add/remove on parsed token lists
// so any class added by another controller is preserved across paints.
export default class extends Controller {
  static targets = ["chip"]
  static values = {
    active: { type: String, default: "all" },
    activeClass: String,
    inactiveClass: String
  }

  connect() {
    this.#paintChips()
    this.#applyFilter()
  }

  filter(event) {
    const next = event.currentTarget.dataset.typeValue || "all"
    // Toggle off if clicking the already-active chip.
    this.activeValue = (next === this.activeValue) ? "all" : next
    this.#paintChips()
    this.#applyFilter()
  }

  #activeTokens() {
    return this.activeClassValue.split(/\s+/).filter(Boolean)
  }

  #inactiveTokens() {
    return this.inactiveClassValue.split(/\s+/).filter(Boolean)
  }

  #paintChips() {
    const activeTokens = this.#activeTokens()
    const inactiveTokens = this.#inactiveTokens()
    this.chipTargets.forEach(chip => {
      const isActive = chip.dataset.typeValue === this.activeValue
      const toAdd = isActive ? activeTokens : inactiveTokens
      const toRemove = isActive ? inactiveTokens : activeTokens
      toRemove.forEach(c => chip.classList.remove(c))
      toAdd.forEach(c => chip.classList.add(c))
    })
  }

  #applyFilter() {
    const active = this.activeValue
    this.element.querySelectorAll("tr[data-field-type]").forEach(row => {
      const matches = active === "all" || row.dataset.fieldType === active
      row.classList.toggle("hidden", !matches)
    })
  }
}
