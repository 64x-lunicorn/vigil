<%* const title = await tp.user.vigil_title(tp) -%>
---
type: event
starts: <% tp.date.now("YYYY-MM-DDTHH:mm:ssZ") %>
ends: <% tp.date.now("YYYY-MM-DDTHH:mm:ssZ", "PT1H") %>
---
# <% title %>

<% tp.file.cursor() %>
