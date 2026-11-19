# Orders

A small order-entry application for a shop that sells coffee machines and their accessories.
The main window has three parts: the **New order** form on the left, the list of **saved
orders** below it, and a log of what MCP clients asked.

## The New order form

| Field | What to enter | Rules |
| - | - | - |
| **Customer** | The customer's company name | Required |
| **Product** | One of Espresso machine, Coffee grinder, Milk frother, Descaling kit | Required, chosen from the list |
| **Quantity** | How many pieces | A whole number from 1 to 100; 1 by default |
| **Delivery date** | The delivery date | A date; a week from today by default |
| **Gift wrap** | Tick it to have the order gift-wrapped | Optional |
| **Notes** | Anything the warehouse should know | Optional, free text |

## Saving an order

**Save order** checks the form: without a customer it says *Customer is required*, without a
product *Product is required*, and nothing is saved. When both are there, the order gets the
next number and appears in the saved orders as one line:

`#3 Acme - 5 x Coffee grinder, delivery 2026-12-01, gift wrap, notes: ring twice`

and the form is cleared for the next one.

**Clear** empties the form without saving anything.

## The saved orders

The list under the form shows every order saved since the application started, newest at
the bottom. Orders are kept in memory only: closing the application loses them.

An order can be deleted only from an MCP client, with the `delete-order` tool, and the
application asks you to confirm first.

## MCP clients

The same form is a tool for MCP clients - Claude Code, Claude Desktop - called
`create-order`, at `http://127.0.0.1:8765/mcp`. A client fills the form, and you click
**Save order**, exactly as when the assistant of this application does it.
