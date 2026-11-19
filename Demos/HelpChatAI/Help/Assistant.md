# Asking the assistant

Press **F1**, or click the round button in the bottom right corner of the window. The
assistant answers from the pages of this manual, and can also fill an order for you.

## Asking it to fill an order

Write the order as you would say it:

> new order for Acme, 5 coffee grinders, delivery next Friday, gift wrapped

The assistant knows the **New order** form with its rules - which fields are required, the
four products, the quantity from 1 to 100. It fills what you told it and says which required
fields are still empty, for you to complete in the form. First it shows what it is about to write and asks you to confirm: **No** is the
default, and nothing happens if you refuse.

Once you confirm, the form is filled and highlighted. **The assistant never saves**: check the
order, correct it if needed, and click **Save order** yourself.

## What it can do

| Ask for | What happens |
| - | - |
| "which forms can you fill?" | It lists the forms of the application it can fill, with what each one is for |
| "new order for Acme, 2 milk frothers" | It fills the New order form, after asking you to confirm |
| "what is still missing in this order?" | It reads the form on screen and tells you |
| "press Clear" | It presses a button of the window. A button that saves is never one it may press |

Typing `/skills` lists these abilities, and `/actions` every action the assistant may use.

## What it sends, and where

The assistant uses Anthropic's Claude. The question you type, the name of the window you are
on, the excerpts of this manual that look relevant and what the form contains leave your
machine and reach Anthropic.
