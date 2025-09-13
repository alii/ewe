select id, title, description, completed
from tasks
where user_id = $1;