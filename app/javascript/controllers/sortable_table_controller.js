import { Controller } from "@hotwired/stimulus"

// In-place sort for a table. Click a sortable <th> to toggle asc/desc.
//
// Markup contract:
//   <table data-controller="sortable-table">
//     <thead>
//       <tr>
//         <th data-action="click->sortable-table#sort"
//             data-sort-type="text">API name <span class="sort-indicator"></span></th>
//         <th data-action="click->sortable-table#sort"
//             data-sort-type="number">Null %  <span class="sort-indicator"></span></th>
//         ...
//       </tr>
//     </thead>
//     <tbody data-sortable-table-target="body">
//       <tr>
//         <td>...</td>
//         <td data-sort-value="0.105">10.5%</td>  // explicit numeric override
//         ...
//       </tr>
//     </tbody>
//   </table>
//
// data-sort-type: "text" (default) | "number"
// data-sort-value (on td): explicit sort key when display text isn't sortable
//   as-is (percentage strings, em-dash placeholders, etc.).
//
// Nulls (empty string, "—", non-numeric in number mode) sort to the bottom
// regardless of direction — common spreadsheet convention.
export default class extends Controller {
  static targets = ["body"]

  sort(event) {
    const th = event.currentTarget
    const headerRow = th.parentElement
    const colIndex = Array.from(headerRow.children).indexOf(th)
    const type = th.dataset.sortType || "text"
    const currentDir = th.dataset.sortDir || "none"
    const nextDir = currentDir === "asc" ? "desc" : "asc"

    // Reset sort state on every sortable header, then set this one.
    headerRow.querySelectorAll("th[data-sort-type]").forEach(h => {
      h.dataset.sortDir = "none"
      const ind = h.querySelector(".sort-indicator")
      if (ind) ind.textContent = ""
    })
    th.dataset.sortDir = nextDir
    const indicator = th.querySelector(".sort-indicator")
    if (indicator) indicator.textContent = nextDir === "asc" ? " ▲" : " ▼"

    // Build pairs of (data row, optional detail row). A row with
    // data-detail-for matches the immediately-preceding data row's
    // data-field-name so inline expansion panels follow their parent
    // row when sorted.
    const allRows = Array.from(this.bodyTarget.querySelectorAll(":scope > tr"))
    const pairs = []
    let i = 0
    while (i < allRows.length) {
      const row = allRows[i]
      if (row.dataset.detailFor) {
        // Orphan detail row (no preceding data row found in pair logic).
        // Keep it where it is by emitting as a solo entry.
        pairs.push([row, null])
        i++
        continue
      }
      const next = allRows[i + 1]
      const detail = next && next.dataset.detailFor === row.dataset.fieldName ? next : null
      pairs.push([row, detail])
      i += detail ? 2 : 1
    }

    pairs.sort((a, b) => {
      const aCell = a[0].children[colIndex]
      const bCell = b[0].children[colIndex]
      const aVal = this.#cellValue(aCell, type)
      const bVal = this.#cellValue(bCell, type)

      // Nulls sort to the bottom regardless of direction.
      if (aVal === null && bVal === null) return 0
      if (aVal === null) return 1
      if (bVal === null) return -1

      let cmp
      if (type === "number") {
        cmp = aVal - bVal
      } else {
        cmp = aVal.localeCompare(bVal)
      }
      return nextDir === "asc" ? cmp : -cmp
    })

    // Re-append data + detail rows together. appendChild moves nodes.
    pairs.forEach(([row, detail]) => {
      this.bodyTarget.appendChild(row)
      if (detail) this.bodyTarget.appendChild(detail)
    })
  }

  #cellValue(cell, type) {
    if (!cell) return null
    const raw = (cell.dataset.sortValue ?? cell.textContent ?? "").trim()
    if (raw === "" || raw === "—") return null
    if (type === "number") {
      const n = parseFloat(raw.replace(/[%,\s]/g, ""))
      return isNaN(n) ? null : n
    }
    return raw.toLowerCase()
  }
}
