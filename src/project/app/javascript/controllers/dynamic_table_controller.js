// app/javascript/controllers/dynamic_table_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "row", "template"] // Tambahkan "template"

  connect() {
    this.updateRowNumbers()
  }

  addRow() {
    const content = this.templateTarget.innerHTML
    this.containerTarget.insertAdjacentHTML("beforeend", content)

    const newRow = this.containerTarget.lastElementChild
    if (newRow) {
      newRow.querySelectorAll("input[type='text'], select").forEach(el => {
        if (el.tagName === "SELECT") {
          el.selectedIndex = 0
        } else {
          el.value = ""
        }
      })
    }
    this.updateRowNumbers()
  }

  removeRow(event) {
    if (this.rowTargets.length > 1) {
      console.log("row dikurang")
      event.target.closest("tr").remove()
      this.updateRowNumbers()
    }
  }

  updateRowNumbers() {
    this.rowTargets.forEach((row, i) => {
      const firstNumberCell = row.querySelector("td:first-child")
      if (firstNumberCell) {
        firstNumberCell.textContent = i + 1
      }
    })
  }
}