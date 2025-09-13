select id, title, description, completed, user_id
from tasks
where id = $1;