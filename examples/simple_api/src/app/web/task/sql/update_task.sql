update
tasks
set title = $1, description = $2, completed = $3
where id = $4 and user_id = $5
returning id, title, description, completed;