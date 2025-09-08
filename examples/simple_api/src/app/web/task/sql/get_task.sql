select id, title, description, completed
from tasks
where id = $1 and user_id = $2;