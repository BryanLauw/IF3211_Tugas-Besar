// app/javascript/controllers/dynamic_table_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "template", "row"]

  connect() {
    // Optional: if you want to ensure row numbers are correct on initial load
    // if repopulating from server.
    // this.updateRowNumbers()
  }

  addRow(event) {
    event.preventDefault()
    
    const content = this.templateTarget.innerHTML
    
    this.containerTarget.insertAdjacentHTML('beforeend', content)
    
    const newRow = this.containerTarget.lastElementChild
    
    newRow.querySelectorAll('input, select, textarea').forEach(field => {
      field.disabled = false
    })
    
    this.updateRowNumbers()
  }

  removeRow(event) {
    event.preventDefault()
    const row = event.target.closest('[data-dynamic-table-target="row"]')
    if (row) {
      row.remove()
      this.updateRowNumbers()
    }
  }

  updateRowNumbers() {
    this.rowTargets.forEach((row, index) => {
      const numberCell = row.querySelector('td:first-child')
      if (numberCell) {
        numberCell.textContent = index + 1
      }
    })
  }
}