1) Clean restart of the stack
   # from the project root
>    docker compose down -v
>    docker compose up -d
   
3) Verify (or create) the publication on the primary DB
>   docker exec -it primary-db psql -U postgres -d flightdb -c "SELECT pubname FROM pg_publication;"
If you don’t see reports_pub in the output, create it:
> docker exec -it primary-db psql -U postgres -d flightdb -c "DROP PUBLICATION IF EXISTS reports_pub; CREATE PUBLICATION reports_pub FOR ALL TABLES;"

3) Create bookings via the app
   >Open the site and create at least one booking (this ensures there’s data to aggregate).

4) Refresh analytics on the reports DB
   > docker exec -it reports-db psql -U postgres -d flightdb -c "SELECT refresh_all_analytics();"
