insert into
tasks (title, description, completed, user_id)
values ($1, $2, $3, $4)
returning id, title, description, completed;